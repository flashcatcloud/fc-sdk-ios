/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import XCTest
import TestUtilities
import DatadogInternal
@testable import DatadogCore

class DirectoriesTests: XCTestCase {
    lazy var directory = Directory(url: temporaryDirectory)

    override func setUp() {
        super.setUp()
        CreateTemporaryDirectory()
    }

    override func tearDown() {
        DeleteTemporaryDirectory()
        super.tearDown()
    }

    func testWhenCreatingCoreDirectory_thenItsNameIsUniqueForClientTokenAndSite() throws {
        // Given
        let fixtures: [(instanceName: String, site: FlashcatSite, expectedName: String)] = [
            ("abcdef", .cn, "e1764cc65da67c6efe39f4e3faaebb6f25e8485f5f98334cfa51f7aa088bb7eb"),
            ("abcdef", .staging, "cf8097e2e7a5c5efd9e38e97bf21b5c7ef06976f67f80dc766a4d81e30e20e19"),
            ("ghijkl", .cn, "c25a5cf2e17eb92eb3f20154d4da4b1cdbdf0f1beda0c354d30b5e3f5d7d6bf6"),
            ("ghijkl", .staging, "45c3e3b21feca61c0308baa31f39a18c8f9d9d98ccdb8ff8a8c1b5c6b8a3d8c9"),
        ]

        // When
        let coreDirectories = try fixtures.map { instanceName, site, _ in
            try CoreDirectory(
                in: directory,
                instanceName: instanceName,
                site: site
            )
        }
        defer { coreDirectories.forEach { $0.delete() } }

        // Then
        zip(fixtures, coreDirectories).forEach { fixture, coreDirectory in
            let directoryName = coreDirectory.coreDirectory.url.lastPathComponent
            XCTAssertEqual(directoryName, fixture.expectedName)
            XCTAssertFalse(
                directoryName.contains(fixture.instanceName),
                "The core directory name must not include client token"
            )
        }
    }

    func testGivenDifferentSDKConfigurations_whenCreatingCoreDirectories_thenEachDirectoryIsUnique() throws {
        // When
        let coreDirectories = try (0..<50).map { index in
            try CoreDirectory(
                in: directory,
                instanceName: .mockRandom(among: .alphanumerics, length: 31) + "\(index)",
                site: .mockRandom()
            )
        }
        defer { coreDirectories.forEach { $0.delete() } }

        // Then
        let uniqueCoreDirectoryURLs = Set(coreDirectories.map({ $0.coreDirectory.url }))
        XCTAssertEqual(
            coreDirectories.count,
            uniqueCoreDirectoryURLs.count,
            "It must create unique core directory URL for each SDK configuration"
        )
    }

    func testGivenCoreDirectory_whenCreatingFeatureDirectories_thenTheirPathsAreRelative() throws {
        // Given
        let coreDirectory = temporaryCoreDirectory.create()
        defer { coreDirectory.delete() }

        // When
        let featureDirectories = try coreDirectory.getFeatureDirectories(forFeatureNamed: .mockRandom())

        // Then
        XCTAssertTrue(
            featureDirectories.authorized.url.path.contains(coreDirectory.coreDirectory.url.path),
            "Feature's authorized directory must be relative to core directory"
        )
        XCTAssertTrue(
            featureDirectories.unauthorized.url.path.contains(coreDirectory.coreDirectory.url.path),
            "Feature's unauthorized directory must be relative to core directory"
        )
    }
}
