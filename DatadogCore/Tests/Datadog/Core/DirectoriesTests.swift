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
            ("abcdef", .cn, "85d075540fc942389a324d43c371fced56b6bb981af4c081b68065b8e6868772"),
            ("abcdef", .staging, "308d710a0422207d664f7ceead3b07cb5dd8030854af5bca13ae3f5312a04961"),
            ("ghijkl", .cn, "09bb1d55569357f5d893b47e4d156e1e06829fb019faec01dde748f61eb6c753"),
            ("ghijkl", .staging, "657c0701dc437c07f476389285e74fe46b7b7b872f59ca7216565c42b1e3b9f2"),
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
