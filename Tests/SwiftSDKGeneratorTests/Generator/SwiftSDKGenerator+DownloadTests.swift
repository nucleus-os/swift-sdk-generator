//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Helpers
import Logging
import SystemPackage
import XCTest

@testable import SwiftSDKGenerator

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

final class SwiftSDKGeneratorDownloadTests: XCTestCase {
    let logger = Logger(label: "SwiftSDKGeneratorDownloadTests")

    private func writeArchive(
        to archiveURL: URL,
        members: [(name: String, contents: Data)]
    ) throws {
        func field(_ value: String, width: Int) -> String {
            precondition(value.utf8.count <= width)
            return value + String(repeating: " ", count: width - value.utf8.count)
        }

        var archive = Data("!<arch>\n".utf8)
        for member in members {
            let header =
                field(member.name, width: 16)
                + field("0", width: 12)
                + field("0", width: 6)
                + field("0", width: 6)
                + field("100644", width: 8)
                + field(String(member.contents.count), width: 10)
                + "`\n"
            precondition(header.utf8.count == 60)
            archive.append(contentsOf: header.utf8)
            archive.append(member.contents)
            if member.contents.count.isMultiple(of: 2) == false {
                archive.append(0x0A)
            }
        }
        try archive.write(to: archiveURL)
    }

    func testExternalSourceRootOwnsGeneratedPaths() async throws {
        let sourceRoot = FilePath("/tmp/nucleus-sdk-generator-output")
        let generator = try await SwiftSDKGenerator(
            bundleVersion: "1.0.0",
            targetTriple: Triple("aarch64-unknown-linux-gnu"),
            artifactID: "nucleus-linux",
            bundleName: "nucleus",
            sourceRoot: sourceRoot,
            isIncremental: false,
            isVerbose: false,
            logger: logger
        )

        let paths = await generator.pathsConfiguration
        XCTAssertEqual(paths.sourceRoot, sourceRoot)
        XCTAssertEqual(
            paths.artifactBundlePath,
            sourceRoot.appending("Bundles/nucleus.artifactbundle")
        )
        XCTAssertEqual(
            paths.artifactsCachePath,
            sourceRoot.appending("Artifacts")
        )
    }

    func testPinnedDebianPackageIsExtractedIntoSDK() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("swift-sdk-generator-download-tests")
            .appendingPathComponent(UUID().uuidString)
        defer { try? fileManager.removeItem(at: rootURL) }

        let packageURL = rootURL.appendingPathComponent("package")
        let payloadURL = packageURL.appendingPathComponent("payload")
        let markerURL = payloadURL.appendingPathComponent("usr/lib/nucleus-marker")
        let controlURL = packageURL.appendingPathComponent("control")
        try fileManager.createDirectory(
            at: markerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(at: controlURL, withIntermediateDirectories: true)
        try Data("nucleus\n".utf8).write(to: markerURL)
        try Data("2.0\n".utf8).write(
            to: packageURL.appendingPathComponent("debian-binary")
        )
        try Data("Package: nucleus-test\nVersion: 1\nArchitecture: all\n".utf8).write(
            to: controlURL.appendingPathComponent("control")
        )

        try await Shell.run(
            "cd \"\(packageURL.path)\" && "
                + "tar -czf data.tar.gz -C payload . && "
                + "tar -czf control.tar.gz -C control ."
        )
        try writeArchive(
            to: packageURL.appendingPathComponent("nucleus-test.deb"),
            members: [
                (
                    "debian-binary",
                    try Data(contentsOf: packageURL.appendingPathComponent("debian-binary"))
                ),
                (
                    "control.tar.gz",
                    try Data(contentsOf: packageURL.appendingPathComponent("control.tar.gz"))
                ),
                (
                    "data.tar.gz",
                    try Data(contentsOf: packageURL.appendingPathComponent("data.tar.gz"))
                ),
            ]
        )

        let generator = try await SwiftSDKGenerator(
            bundleVersion: "1.0.0",
            targetTriple: Triple("aarch64-unknown-linux-gnu"),
            artifactID: "nucleus-linux",
            sourceRoot: FilePath(rootURL.path),
            isIncremental: false,
            isVerbose: false,
            logger: logger
        )
        let sdkPath = FilePath(rootURL.appendingPathComponent("sdk").path)
        try await generator.createDirectoryIfNeeded(at: sdkPath)
        try await generator.installDebianPackages(
            [FilePath(packageURL.appendingPathComponent("nucleus-test.deb").path)],
            sdkDirPath: sdkPath
        )

        let installedMarker = rootURL.appendingPathComponent("sdk/usr/lib/nucleus-marker")
        XCTAssertEqual(try String(contentsOf: installedMarker, encoding: .utf8), "nucleus\n")
        XCTAssertEqual(
            try fileManager.destinationOfSymbolicLink(
                atPath: rootURL.appendingPathComponent("sdk/lib").path
            ),
            "./usr/lib"
        )
    }
}
