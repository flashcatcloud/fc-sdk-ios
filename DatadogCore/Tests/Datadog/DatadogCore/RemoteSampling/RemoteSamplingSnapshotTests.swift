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

    func testRejectsABodyThatIsNotRecognisablyAConfiguration() {
        // Every field the contract makes mandatory is checked, not just one of them. A 200 is no
        // proof the body came from the configuration endpoint, and taking something else for one
        // is not a wasted request: `version` is a floor that only ever moves forward, so a stray
        // number stored here refuses every genuine answer beneath it — the console's own repair
        // included — until the app is reinstalled.
        let bodies = [
            #"not json"#,
            #"["array"]"#,
            #"{ "version": 1, "enabled": true, "rum": {} }"#, // no schema stamp at all
            #"{ "schema_version": null, "version": 1, "enabled": true, "rum": {} }"#, // an explicit null is no stamp
            #"{ "schema_version": 1, "version": "42", "enabled": true }"#, // version of wrong type
            #"{ "schema_version": 1, "version": 1.5, "enabled": true }"#, // a publish counter is a whole number
            #"{ "schema_version": 1, "version": -1, "enabled": true }"#, // and never negative
            #"{ "schema_version": 1, "enabled": true, "rum": {} }"#, // no version
            #"{ "schema_version": 1, "version": 1 }"#, // no kill switch
            #"{ "schema_version": 1, "version": 1, "enabled": "yes" }"#, // enabled of wrong type
            #"{ "schema_version": 1, "version": 1, "enabled": true, "rum": "nope" }"#, // rum of wrong type
            #"{ "schema_version": 1, "version": 1, "enabled": false, "rum": "nope" }"#, // ... even behind the kill switch
        ]

        for string in bodies {
            let body = string.data(using: .utf8)!
            XCTAssertThrowsError(try RemoteSamplingResponse.parse(body: body, etag: .mockAny()), "should reject: \(string)") { error in
                XCTAssertTrue(
                    error is RemoteSamplingResponseError,
                    "should read as an unreadable body, which is worth asking again for: \(string)"
                )
            }
        }
    }

    func testAnActivationItCannotReadDoesNotCostItTheConfiguration() throws {
        // The one field that must not refuse a body. Reading by whitelist exists so that an older
        // SDK can still talk to a newer console; refusing here would mean that the day the server
        // learns a third way to apply a change, every client on this version stops accepting any
        // configuration at all — rates included, which have nothing to do with it.
        let body = #"""
        { "schema_version": 1, "version": 1, "enabled": true, "activation": "sometimes", "rum": { "sessionSampleRate": 20 } }
        """#.data(using: .utf8)!

        let response = try RemoteSamplingResponse.parse(body: body, etag: .mockAny())

        XCTAssertEqual(response.snapshot.sessionSampleRate, 20, "the values still apply")
        XCTAssertEqual(response.activation, .nextSession, "and the running session is left alone, which is the safe reading")
    }

    func testAKnobItCannotUseDoesNotCostItTheConfiguration() throws {
        // A rate we cannot trust is never clamped — it is not a rate to sample a customer's
        // traffic with. But only that field is dropped: refusing the response would take the
        // version and the custom values down with it, and because the version is a floor, keep
        // them down. The web and Android SDKs read it the same way.
        let bodies = [
            #"{ "schema_version": 1, "version": 3, "enabled": true, "rum": { "sessionSampleRate": -1 }, "custom": { "a": 1 } }"#,
            #"{ "schema_version": 1, "version": 3, "enabled": true, "rum": { "sessionSampleRate": 100.5 }, "custom": { "a": 1 } }"#,
            #"{ "schema_version": 1, "version": 3, "enabled": true, "rum": { "sessionSampleRate": "20" }, "custom": { "a": 1 } }"#,
        ]

        for string in bodies {
            let response = try RemoteSamplingResponse.parse(body: string.data(using: .utf8)!, etag: .mockAny())
            XCTAssertNil(response.snapshot.sessionSampleRate, "the init value keeps applying: \(string)")
            XCTAssertEqual(response.snapshot.version, 3, "the rest of the configuration still lands: \(string)")
            XCTAssertEqual(response.snapshot.custom, #"{"a":1}"#, "including the values beside it: \(string)")
        }
    }

    func testACustomBagItCannotReadDoesNotCostItTheKnobs() throws {
        // The application's own bag is not part of what makes a body a configuration. A mistake at
        // the application's level must not switch the platform's settings back off.
        let body = #"""
        { "schema_version": 1, "version": 3, "enabled": true, "rum": { "sessionSampleRate": 20 }, "custom": "nope" }
        """#.data(using: .utf8)!

        let response = try RemoteSamplingResponse.parse(body: body, etag: .mockAny())

        XCTAssertNil(response.snapshot.custom)
        XCTAssertEqual(response.snapshot.sessionSampleRate, 20)
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

    // MARK: - Fuzzing the envelope

    /// Deterministic, so a body that breaks this can be reproduced from the seed alone.
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            self.state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed // xorshift is stuck at zero
        }

        mutating func next() -> UInt64 {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            return state &* 2_685_821_657_736_338_717
        }
    }

    /// JSON values worth substituting into a response: every shape a server, a proxy or an
    /// intermediary might put where the contract expects something else.
    private static let junkValues: [Any] = [
        NSNull(),
        "1", "true", "", "20",
        0, 1, 2, -1, 1.5, 100.5, 9_999_999_999_999_999_999.0,
        true, false,
        [Any](), ["a"], [1, 2],
        [String: Any](), ["sessionSampleRate": 20], ["nested": ["deep": 1]]
    ]

    private func aValidBody() -> [String: Any] {
        [
            "schema_version": 1,
            "version": 42,
            "ttl": 600,
            "enabled": true,
            "activation": "next_session",
            "refresh_on_foreground": false,
            "rum": ["sessionSampleRate": 20],
            "custom": ["viplist": ["u-1"]]
        ]
    }

    /// `JSONSerialization` bridges JSON booleans to `NSNumber`, so `is Bool` is true of any number.
    /// The reader under test tells them apart this way and so must anything checking its work.
    private func isJSONBoolean(_ value: Any?) -> Bool {
        guard let value = value else {
            return false
        }
        return CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
    }

    private func mutatedBodies(count: Int, seed: UInt64) -> [Data] {
        var generator = SeededGenerator(seed: seed)
        var bodies: [Data] = []

        while bodies.count < count {
            switch Int.random(in: 0..<6, using: &generator) {
            case 0: // pure noise
                let length = Int.random(in: 0..<64, using: &generator)
                bodies.append(Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }))
            case 1: // a key removed
                var body = aValidBody()
                if let key = body.keys.sorted().randomElement(using: &generator) {
                    body.removeValue(forKey: key)
                }
                bodies.append(contentsOf: serialize(body))
            case 2: // a key given something else
                var body = aValidBody()
                if let key = body.keys.sorted().randomElement(using: &generator),
                   let junk = Self.junkValues.randomElement(using: &generator) {
                    body[key] = junk
                }
                bodies.append(contentsOf: serialize(body))
            case 3: // a knob given something else
                var body = aValidBody()
                if let junk = Self.junkValues.randomElement(using: &generator) {
                    body["rum"] = ["sessionSampleRate": junk]
                }
                bodies.append(contentsOf: serialize(body))
            case 4: // truncated
                let full = serialize(aValidBody()).first ?? Data()
                let cut = Int.random(in: 0..<max(full.count, 1), using: &generator)
                bodies.append(full.prefix(cut))
            default: // one byte flipped
                var full = serialize(aValidBody()).first ?? Data()
                if !full.isEmpty {
                    let index = Int.random(in: 0..<full.count, using: &generator)
                    full[index] = UInt8.random(in: 0...255, using: &generator)
                }
                bodies.append(full)
            }
        }
        return bodies
    }

    /// Empty rather than throwing, so a body this test cannot even build simply does not get tried.
    private func serialize(_ body: [String: Any]) -> [Data] {
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body) else {
            return []
        }
        return [data]
    }

    func testNothingReachesTheVersionFloorWithoutCarryingTheEnvelope() {
        // The version a body gets accepted with becomes a floor that only ever moves forward, so
        // the question worth asking of an arbitrary body is not whether it is read correctly but
        // whether it can get that far at all. Mutations of a real response and pure noise are both
        // thrown at the reader; of anything it accepts, the body must genuinely have carried the
        // envelope, and the version reported must be the one the body actually named.
        //
        // Reaching the end of the loop at all is the other half of what this measures: the reader
        // takes arbitrary bytes from the network, and it must never be the thing that crashes.
        var accepted = 0
        var refused = 0

        for body in mutatedBodies(count: 3_000, seed: 0x5EED) {
            guard let response = try? RemoteSamplingResponse.parse(body: body, etag: nil) else {
                refused += 1
                continue
            }
            accepted += 1

            let root = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]) ?? [:]
            XCTAssertEqual(
                (root["schema_version"] as? NSNumber).map { $0.intValue },
                1,
                "accepted a body whose schema stamp was not 1"
            )
            XCTAssertFalse(isJSONBoolean(root["schema_version"]), "a boolean is not a schema stamp")
            XCTAssertTrue(isJSONBoolean(root["enabled"]), "accepted a body whose kill switch was not a boolean")
            if let rum = root["rum"] {
                XCTAssertTrue(rum is [String: Any], "accepted a body whose rum was not an object")
            }

            let named = try? XCTUnwrap(root["version"] as? NSNumber)
            XCTAssertEqual(response.snapshot.version, named?.int64Value, "reported a version the body did not name")
            XCTAssertEqual(Double(response.snapshot.version), named?.doubleValue, "accepted a version that was not whole")
        }

        // The fuzzer's own negative control. All-refused would satisfy every assertion above while
        // measuring nothing, and all-accepted would mean the mutations never reached the envelope.
        XCTAssertGreaterThan(accepted, 100, "hardly any body was accepted — the assertions above barely ran")
        XCTAssertGreaterThan(refused, 100, "hardly any body was refused — the mutations are not reaching the envelope")
    }

    // MARK: - Schema

    func testRefusesASchemaItDoesNotRead() {
        let bodies = [
            #"{ "schema_version": 2, "version": 1, "enabled": true, "rum": { "sessionSampleRate": 20 } }"#,
            #"{ "schema_version": 0, "version": 1, "enabled": true }"#,
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

    func testAStampThatIsNotANumberIsNotAStamp() {
        // `"1"` must not be quietly read as `1`: the whole point of the field is that every SDK
        // agrees about the same response. A stamp we cannot even read means this is not our
        // envelope, which is the unreadable-body answer, not the unknown-schema one.
        let bodies = [
            #"{ "schema_version": "1", "version": 1, "enabled": true }"#,
            #"{ "schema_version": true, "version": 1, "enabled": true }"#, // JSON bools bridge to NSNumber
        ]

        for string in bodies {
            let body = string.data(using: .utf8)!
            XCTAssertThrowsError(try RemoteSamplingResponse.parse(body: body, etag: .mockAny()), "should refuse: \(string)") { error in
                XCTAssertTrue(error is RemoteSamplingResponseError, "should refuse as unreadable: \(string)")
            }
        }
    }

    func testABodyWithNoSchemaStampIsNotAConfiguration() {
        // Refused, and refused as UNREADABLE rather than as a schema we do not know: no server
        // predating the stamp exists — this endpoint has stamped every response since it existed —
        // so an unstamped body did not come from it, and the next answer may well come from the
        // real endpoint. Accepting one would leave `version` as the only thing telling a
        // configuration apart from any other JSON object carrying a number, which is exactly what
        // a captive portal or a misrouted proxy supplies. See `checkSchemaVersion`.
        let bodies = [
            #"{ "version": 1, "enabled": true, "rum": { "sessionSampleRate": 20 } }"#, // no key at all
            #"{ "schema_version": null, "version": 1, "enabled": true, "rum": { "sessionSampleRate": 20 } }"#,
        ]

        for string in bodies {
            let body = string.data(using: .utf8)!
            XCTAssertThrowsError(try RemoteSamplingResponse.parse(body: body, etag: .mockAny()), "should refuse: \(string)") { error in
                XCTAssertTrue(error is RemoteSamplingResponseError, "should be worth asking again for: \(string)")
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
