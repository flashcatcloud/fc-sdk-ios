/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import DatadogInternal
import TestUtilities
import XCTest
@testable import DatadogCore

class RemoteSamplingSnapshotTests: XCTestCase {
    // MARK: - Parsing & validation

    func testParsesFullResponse() throws {
        let body = """
        {
            "schema_version": 1,
            "version": 42, "ttl": 600, "enabled": true,
            "activation": "next_session",
            "refresh_on_foreground": false,
            "rum": {
                "sessionSampleRate": 20
            },
            "custom": { "viplist": ["u-1"] }
        }
        """.data(using: .utf8)!

        let response = try RemoteSamplingResponse.parse(body: body, etag: .mockAny())

        XCTAssertEqual(response.activation, .nextSession)
        XCTAssertEqual(response.snapshot.version, 42)
        XCTAssertTrue(response.snapshot.enabled)
        XCTAssertEqual(response.snapshot.sessionSampleRate, 20)
        XCTAssertEqual(response.snapshot.custom, #"{"viplist":["u-1"]}"#)
    }

    func testAbsentKnobsStayAbsentNotZero() throws {
        let body = #"{ "schema_version": 1, "version": 7, "enabled": true, "rum": {} }"#.data(using: .utf8)!

        let response = try RemoteSamplingResponse.parse(body: body, etag: .mockAny())

        XCTAssertNil(response.snapshot.sessionSampleRate)
        XCTAssertNil(response.snapshot.custom)
    }

    func testIgnoresUnknownKeys() throws {
        let body = #"""
        { "schema_version": 1, "version": 7, "enabled": true, "future-field": { "anything": 1 }, "rum": { "sessionSampleRate": 30, "futureKnob": 9 } }
        """#.data(using: .utf8)!

        let response = try RemoteSamplingResponse.parse(body: body, etag: .mockAny())

        XCTAssertEqual(response.snapshot.sessionSampleRate, 30)
    }

    func testRejectsWholeSnapshotOnInvalidType() {
        let bodies = [
            #"not json"#,
            #"["array"]"#,
            #"{ "schema_version": 1, "version": "42", "enabled": true }"#, // version of wrong type
            #"{ "schema_version": 1, "enabled": true, "rum": {} }"#, // no version
            #"{ "schema_version": 1, "version": 1, "enabled": "yes" }"#, // enabled of wrong type
            #"{ "schema_version": 1, "version": 1, "enabled": true, "activation": "sometimes" }"#, // unknown activation
            #"{ "schema_version": 1, "version": 1, "enabled": true, "rum": "nope" }"#, // rum of wrong type
            #"{ "schema_version": 1, "version": 1, "enabled": true, "custom": "nope" }"#, // custom of wrong type
            #"{ "schema_version": 1, "version": 1, "enabled": true, "rum": { "sessionSampleRate": "20" } }"#, // rate of wrong type
        ]

        for string in bodies {
            let body = string.data(using: .utf8)!
            XCTAssertThrowsError(try RemoteSamplingResponse.parse(body: body, etag: .mockAny()), "should reject: \(string)")
        }
    }

    func testRejectsWholeSnapshotOnOutOfRangeRate() {
        for rate in [-1, 100.5] {
            let body = #"{ "schema_version": 1, "version": 1, "enabled": true, "rum": { "sessionSampleRate": \#(rate) } }"#.data(using: .utf8)!
            XCTAssertThrowsError(try RemoteSamplingResponse.parse(body: body, etag: .mockAny()))
        }
    }

    func testAcceptsBoundaryRates() throws {
        for rate in [0, 100] {
            let body = #"{ "schema_version": 1, "version": 1, "enabled": true, "rum": { "sessionSampleRate": \#(rate) } }"#.data(using: .utf8)!
            let response = try RemoteSamplingResponse.parse(body: body, etag: .mockAny())
            XCTAssertEqual(response.snapshot.sessionSampleRate, SampleRate(rate))
        }
    }

    func testKillSwitchClearsValuesKeepsVersion() throws {
        let body = #"""
        { "schema_version": 1, "version": 43, "enabled": false, "rum": {}, "custom": { "viplist": ["u-1"] } }
        """#.data(using: .utf8)!

        let response = try RemoteSamplingResponse.parse(body: body, etag: .mockAny())
        let rates = response.snapshot.rates

        XCTAssertEqual(response.snapshot.version, 43)
        XCTAssertFalse(response.snapshot.enabled)
        XCTAssertNil(response.snapshot.custom)
        XCTAssertNil(rates.sessionSampleRate)
        XCTAssertNil(rates.custom)
        XCTAssertEqual(rates.version, 43, "the version survives the kill switch")
    }

    func testRatesReflectSnapshot() throws {
        let body = #"""
        { "schema_version": 1, "version": 42, "enabled": true, "rum": { "sessionSampleRate": 20 }, "custom": { "a": 1 } }
        """#.data(using: .utf8)!

        let rates = try RemoteSamplingResponse.parse(body: body, etag: .mockAny()).snapshot.rates

        XCTAssertEqual(rates.sessionSampleRate, 20)
        XCTAssertEqual(rates.version, 42)
        XCTAssertEqual(rates.custom, #"{"a":1}"#)
    }

    // MARK: - Schema

    func testRefusesASchemaItDoesNotRead() {
        let bodies = [
            #"{ "schema_version": 2, "version": 1, "enabled": true, "rum": { "sessionSampleRate": 20 } }"#,
            #"{ "version": 1, "enabled": true, "rum": { "sessionSampleRate": 20 } }"#, // no schema at all
            #"{ "schema_version": "1", "version": 1, "enabled": true }"#, // schema of wrong type
            #"{ "schema_version": true, "version": 1, "enabled": true }"#, // JSON bools bridge to NSNumber
        ]

        for string in bodies {
            let body = string.data(using: .utf8)!
            XCTAssertThrowsError(try RemoteSamplingResponse.parse(body: body, etag: .mockAny()), "should refuse: \(string)") { error in
                // Refused as a schema we cannot read, not as an unreadable body: the two get
                // opposite answers from the controller.
                XCTAssertTrue(error is RemoteSamplingUnsupportedSchemaError, "should refuse on schema: \(string)")
            }
        }
    }

    func testReadsTheSchemaItSupports() throws {
        let body = #"{ "schema_version": 1, "version": 1, "enabled": true, "rum": { "sessionSampleRate": 20 } }"#
            .data(using: .utf8)!

        let response = try RemoteSamplingResponse.parse(body: body, etag: .mockAny())

        XCTAssertEqual(response.snapshot.sessionSampleRate, 20)
    }

    // MARK: - ETag

    func testETagIsQuotedHashPrefix() {
        let body = #"{ "version": 1 }"#.data(using: .utf8)!

        let etag = remoteSamplingETag(for: body)

        XCTAssertTrue(etag.hasPrefix("\""))
        XCTAssertTrue(etag.hasSuffix("\""))
        XCTAssertEqual(etag.count, 18, "16 hex characters plus the quotes")
        let same = remoteSamplingETag(for: body)
        XCTAssertEqual(etag, same, "ETag must be stable for the same body")
        let other = remoteSamplingETag(for: #"{ "version": 2 }"#.data(using: .utf8)!)
        XCTAssertNotEqual(etag, other)
    }

    // MARK: - Persistence

    func testStorageKeyComposition() {
        let source = RemoteSamplingSource(configurationURL: URL(string: "https://intake.example.com/api/v2/rum/config?client_token=t")!)
        let base: DatadogContext = .mockWith(
            clientToken: "t",
            service: "shop",
            env: "prod",
            version: "1.2.3",
            sdkVersion: "2.0.0",
            applicationBundleIdentifier: "com.example.shop"
        )
        let key = RemoteSamplingSnapshotStore.key(source: source, context: base)

        // SDK version is deliberately not part of the key:
        let otherSDK: DatadogContext = .mockWith(
            clientToken: "t",
            service: "shop",
            env: "prod",
            version: "1.2.3",
            sdkVersion: "9.9.9",
            applicationBundleIdentifier: "com.example.shop"
        )
        XCTAssertEqual(key, RemoteSamplingSnapshotStore.key(source: source, context: otherSDK))

        // Everything else that identifies a configuration is:
        let otherAppVersion: DatadogContext = .mockWith(
            clientToken: "t", service: "shop", env: "prod", version: "9.9.9", applicationBundleIdentifier: "com.example.shop"
        )
        XCTAssertNotEqual(key, RemoteSamplingSnapshotStore.key(source: source, context: otherAppVersion))

        let otherEnv: DatadogContext = .mockWith(
            clientToken: "t", service: "shop", env: "staging", version: "1.2.3", applicationBundleIdentifier: "com.example.shop"
        )
        XCTAssertNotEqual(key, RemoteSamplingSnapshotStore.key(source: source, context: otherEnv))

        let otherService: DatadogContext = .mockWith(
            clientToken: "t", service: "other", env: "prod", version: "1.2.3", applicationBundleIdentifier: "com.example.shop"
        )
        XCTAssertNotEqual(key, RemoteSamplingSnapshotStore.key(source: source, context: otherService))

        let otherHost = RemoteSamplingSource(configurationURL: URL(string: "https://other.example.com/api/v2/rum/config")!)
        XCTAssertNotEqual(key, RemoteSamplingSnapshotStore.key(source: otherHost, context: base))
    }

    func testStoreRoundTrip() throws {
        CreateTemporaryDirectory()
        defer { DeleteTemporaryDirectory() }

        let coreDirectory = CoreDirectory(
            osDirectory: Directory(url: temporaryDirectory),
            coreDirectory: try Directory(url: temporaryDirectory).createSubdirectory(path: "core-\(UUID().uuidString)")
        )
        let store = try RemoteSamplingSnapshotStore(coreDirectory: coreDirectory)
        let snapshot = RemoteSamplingSnapshot(
            version: 42,
            etag: "\"0123456789abcdef\"",
            enabled: true,
            sessionSampleRate: 20,
            custom: #"{"a":1}"#
        )

        store.save(snapshot, forKey: "key")
        XCTAssertEqual(store.load(forKey: "key"), snapshot)
        XCTAssertNil(store.load(forKey: "other-key"))
    }
}
