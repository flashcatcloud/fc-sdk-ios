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

    func testReadsABodyWithNoSchemaStampAtAll() throws {
        // A body with no stamp is, by construction, the shape that existed before the stamp did —
        // the shape this reader was written against. Refusing it would switch remote configuration
        // silently off for every client on this platform against a server that merely predates the
        // field, and nothing would say so.
        let bodies = [
            #"{ "version": 1, "enabled": true, "rum": { "sessionSampleRate": 20 } }"#, // no key at all
            #"{ "schema_version": null, "version": 1, "enabled": true, "rum": { "sessionSampleRate": 20 } }"#,
        ]

        for string in bodies {
            let body = string.data(using: .utf8)!
            let response = try RemoteSamplingResponse.parse(body: body, etag: .mockAny())
            XCTAssertEqual(response.snapshot.sessionSampleRate, 20, "should read: \(string)")
        }
    }

    func testReadsTheSchemaItSupports() throws {
        let body = #"{ "schema_version": 1, "version": 1, "enabled": true, "rum": { "sessionSampleRate": 20 } }"#
            .data(using: .utf8)!

        let response = try RemoteSamplingResponse.parse(body: body, etag: .mockAny())

        XCTAssertEqual(response.snapshot.sessionSampleRate, 20)
    }

    // MARK: - ETag

    func testTheServersValidatorIsKeptVerbatim() throws {
        let body = #"{ "schema_version": 1, "version": 1, "enabled": true, "rum": {} }"#.data(using: .utf8)!

        let response = try RemoteSamplingResponse.parse(body: body, etag: "W/\"0123456789abcdef\"")

        XCTAssertEqual(
            response.snapshot.etag,
            "W/\"0123456789abcdef\"",
            "whatever the server stamped goes back on the next request untouched, weak form included"
        )
    }

    func testAResponseWithoutAValidatorIsStillAccepted() throws {
        let body = #"{ "schema_version": 1, "version": 1, "enabled": true, "rum": {} }"#.data(using: .utf8)!

        let response = try RemoteSamplingResponse.parse(body: body, etag: nil)

        XCTAssertNil(response.snapshot.etag, "with nothing to revalidate against, the next request simply asks in full")
        XCTAssertEqual(response.snapshot.version, 1, "a missing validator is not a reason to reject the configuration")
    }

    // MARK: - Persistence

    func testStorageKeyNamesOnlyWhatChangesTheAnswer() {
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

        // The environment is matched on by the server, so two of them are two configurations:
        let otherEnv: DatadogContext = .mockWith(clientToken: "t", service: "shop", env: "staging", version: "1.2.3")
        XCTAssertNotEqual(key, RemoteSamplingSnapshotStore.key(source: source, context: otherEnv))

        // So is the intake the answer came from, which an application can point elsewhere:
        let otherHost = RemoteSamplingSource(configurationURL: URL(string: "https://other.example.com/api/v2/rum/config")!)
        XCTAssertNotEqual(key, RemoteSamplingSnapshotStore.key(source: otherHost, context: base))

        // The client token names the application, and versions are counted per application. An
        // entry written for another one is not just wrong, it is AHEAD — see the controller test
        // that shows what the version guard would otherwise do with it.
        let otherToken: DatadogContext = .mockWith(clientToken: "other", service: "shop", env: "prod", version: "1.2.3")
        XCTAssertNotEqual(key, RemoteSamplingSnapshotStore.key(source: source, context: otherToken))

        // The application version is not, though the server does match on it: keying by it would
        // put the first session after every release back on the value the app was built with, to
        // guard against settings that at worst are one release out of date until the next fetch.
        let otherAppVersion: DatadogContext = .mockWith(clientToken: "t", service: "shop", env: "prod", version: "9.9.9")
        XCTAssertEqual(key, RemoteSamplingSnapshotStore.key(source: source, context: otherAppVersion))

        // Nor is the service name — the server is never told it, so it cannot change the answer.
        let otherService: DatadogContext = .mockWith(clientToken: "t", service: "other", env: "prod", version: "1.2.3")
        XCTAssertEqual(key, RemoteSamplingSnapshotStore.key(source: source, context: otherService))

        // Nor the SDK version: an SDK update must not throw away the console's answer.
        let otherSDK: DatadogContext = .mockWith(clientToken: "t", service: "shop", env: "prod", version: "1.2.3", sdkVersion: "9.9.9")
        XCTAssertEqual(key, RemoteSamplingSnapshotStore.key(source: source, context: otherSDK))

        // Nor the bundle identifier: the store lives in the application's own container, so one
        // key is only ever reachable by one bundle.
        let otherBundle: DatadogContext = .mockWith(
            clientToken: "t", service: "shop", env: "prod", version: "1.2.3", applicationBundleIdentifier: "com.example.other"
        )
        XCTAssertEqual(key, RemoteSamplingSnapshotStore.key(source: source, context: otherBundle))
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

    func testLoadingRemovesEntriesNoConfigurationCanReadAgain() throws {
        CreateTemporaryDirectory()
        defer { DeleteTemporaryDirectory() }

        let coreDirectory = try Directory(url: temporaryDirectory).createSubdirectory(path: "core-\(UUID().uuidString)")
        let store = try RemoteSamplingSnapshotStore(
            coreDirectory: CoreDirectory(osDirectory: Directory(url: temporaryDirectory), coreDirectory: coreDirectory)
        )
        // The store keeps its entries in a subdirectory of the core directory; that is what to look in.
        let entries = try coreDirectory.subdirectory(path: "remote-config")
        let snapshot = RemoteSamplingSnapshot(version: 1, etag: nil, enabled: true, sessionSampleRate: 20, custom: nil)

        // Two releases' worth of entries, as an app that shipped twice would leave behind:
        store.save(snapshot, forKey: "app-1.0.0")
        store.save(snapshot, forKey: "app-1.0.1")

        // The launch that can no longer read them is the launch that removes them:
        XCTAssertNil(store.load(forKey: "app-1.0.2"))

        XCTAssertEqual(try entries.files().map { $0.name }, [], "nothing will ever read an entry written under another key")

        // And the entry in use survives its own load:
        store.save(snapshot, forKey: "app-1.0.2")
        XCTAssertEqual(store.load(forKey: "app-1.0.2"), snapshot)
        XCTAssertEqual(try entries.files().map { $0.name }, ["app-1.0.2"])
    }
}
