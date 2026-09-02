/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation
import DatadogInternal

/// The last configuration the console provided, as the client keeps it.
///
/// A snapshot is activated all-or-nothing: a response that does not parse or that carries a value
/// of the wrong shape is rejected whole and the previous snapshot stays in effect.
internal struct RemoteSamplingSnapshot: Equatable, Codable {
    /// The console's version of this configuration. `0` means the console never provided one.
    var version: Int64
    /// The validator the next conditional request is sent with; `nil` until the first `200`.
    var etag: String?
    /// Whether the console wants remote configuration applied at all.
    ///
    /// `false` is the kill switch: every knob is cleared (so the app falls back to the values it
    /// was initialised with) but the version is kept, so the client still reports what it runs.
    var enabled: Bool
    var sessionSampleRate: SampleRate?
    /// The console's custom values, as the raw JSON object they were delivered in.
    var custom: String?

    /// The snapshot before the console answers for the first time.
    static let empty = RemoteSamplingSnapshot(
        version: 0,
        etag: nil,
        enabled: false,
        sessionSampleRate: nil,
        custom: nil
    )

    /// The rates RUM draws each new session with.
    var rates: RemoteSamplingRates {
        guard enabled else {
            // Kill switch: no knob and no custom values, only the version survives.
            return RemoteSamplingRates(
                sessionSampleRate: nil,
                version: version
            )
        }
        return RemoteSamplingRates(
            sessionSampleRate: sessionSampleRate,
            version: version,
            custom: custom
        )
    }
}

/// The outcome of reading a `200` response body against the configuration contract.
internal struct RemoteSamplingResponse: Equatable {
    let snapshot: RemoteSamplingSnapshot
    let activation: RemoteSamplingActivation
}

/// An unparseable or invalid configuration response. Carries no details on purpose:
/// the handling is the same whatever is wrong — keep the old snapshot.
internal struct RemoteSamplingResponseError: Error {}

/// A configuration written to a contract this SDK does not read.
///
/// Kept apart from `RemoteSamplingResponseError` because the two deserve opposite answers: an
/// unreadable body is worth asking again for, a schema we do not know is not — the next answer
/// would be the same refusal.
internal struct RemoteSamplingUnsupportedSchemaError: Error {
    let received: Int?
}

extension RemoteSamplingResponse {
    /// Reads a configuration response body.
    ///
    /// The contract is a flat JSON object. Keys the SDK does not know are ignored, so an older SDK
    /// can talk to a newer console. A known key carrying the wrong type — or a rate outside
    /// 0...100 — rejects the whole response: half-activated configuration is worse than none.
    ///
    /// - Parameters:
    ///   - body: The response body.
    ///   - etag: The validator the server stamped this body with, or nil when it sent none —
    ///     the next request then simply asks unconditionally.
    static func parse(body: Data, etag: String?) throws -> RemoteSamplingResponse {
        guard let json = try? JSONSerialization.jsonObject(with: body),
              let root = json as? [String: Any] else {
            throw RemoteSamplingResponseError()
        }

        // Checked before anything else is read out of the body. The server states the shape it
        // wrote, and a reader that guesses instead of checking is exactly what this field exists
        // to prevent — which is why it has to be honoured by the first SDK that ships, not by a
        // later one: only code already on the device can refuse.
        try checkSchemaVersion(root)

        let version = try readVersion(root)
        let enabled = try readBoolean(root, key: Contract.enabled, default: false)
        let activation = try readActivation(root)

        guard enabled else {
            // Kill switch: clear every knob, keep the version. `rum` and `custom` are not read —
            // the console sends `rum: {}` here, and whatever it carries must not apply.
            return RemoteSamplingResponse(
                snapshot: RemoteSamplingSnapshot(
                    version: version,
                    etag: etag,
                    enabled: false,
                    sessionSampleRate: nil,
                    custom: nil
                ),
                activation: activation
            )
        }

        let rum = try readDictionary(root, key: Contract.rum) ?? [:]
        let custom = try readCustom(root)

        return RemoteSamplingResponse(
            snapshot: RemoteSamplingSnapshot(
                version: version,
                etag: etag,
                enabled: true,
                sessionSampleRate: try readRate(rum, key: Contract.sessionSampleRate),
                custom: custom
            ),
            activation: activation
        )
    }

    // MARK: - Whitelisted readers

    /// The contract this SDK reads. Not the SDK version and not the settings version: it names the
    /// SHAPE of the body, and the server bumps it only when a body would be misread by a reader
    /// written against the previous shape.
    static let supportedSchemaVersion = 1

    private static func checkSchemaVersion(_ root: [String: Any]) throws {
        // A body carrying no stamp at all is, by construction, the shape that existed before the
        // stamp did — which is the shape this reader was written against. Refusing it would switch
        // remote configuration silently off for every client on this platform whenever it is
        // pointed at a server that merely predates the field, and nothing would say so. Only a
        // stamp we can see and do not recognise is a reason to refuse.
        // A key that is absent, or present as an explicit null, both say the same thing: nothing
        // was stamped. The other SDKs read them the same way.
        guard let raw = root[Contract.schemaVersion], !(raw is NSNull) else {
            return
        }
        guard let number = raw as? NSNumber, !isBoolean(raw), number.intValue == supportedSchemaVersion else {
            let received = (raw as? NSNumber).map { $0.intValue }
            throw RemoteSamplingUnsupportedSchemaError(received: received)
        }
    }

    private enum Contract {
        static let schemaVersion = "schema_version"
        static let version = "version"
        static let enabled = "enabled"
        static let activation = "activation"
        static let rum = "rum"
        static let custom = "custom"
        static let sessionSampleRate = "sessionSampleRate"
    }

    private static func readVersion(_ root: [String: Any]) throws -> Int64 {
        guard let raw = root[Contract.version] else {
            throw RemoteSamplingResponseError() // a configuration without a version cannot be reported back
        }
        guard let version = raw as? NSNumber, !isBoolean(raw), version.int64Value >= 0 else {
            throw RemoteSamplingResponseError()
        }
        return version.int64Value
    }

    private static func readBoolean(_ root: [String: Any], key: String, default defaultValue: Bool) throws -> Bool {
        guard let raw = root[key] else {
            return defaultValue
        }
        guard let number = raw as? NSNumber, isBoolean(raw) else {
            throw RemoteSamplingResponseError()
        }
        return number.boolValue
    }

    private static func readActivation(_ root: [String: Any]) throws -> RemoteSamplingActivation {
        guard let raw = root[Contract.activation] else {
            return .nextSession
        }
        guard let string = raw as? String, let activation = RemoteSamplingActivation(rawValue: string) else {
            throw RemoteSamplingResponseError()
        }
        return activation
    }

    private static func readDictionary(_ root: [String: Any], key: String) throws -> [String: Any]? {
        guard let raw = root[key] else {
            return nil
        }
        guard let dictionary = raw as? [String: Any] else {
            throw RemoteSamplingResponseError()
        }
        return dictionary
    }

    /// A rate the response did not send stays absent, so the value passed to init keeps applying.
    /// A rate outside 0...100 rejects the whole response rather than being clamped: a rate we
    /// cannot trust is not a rate to sample a customer's traffic with.
    private static func readRate(_ rum: [String: Any], key: String) throws -> SampleRate? {
        guard let raw = rum[key] else {
            return nil
        }
        guard let number = raw as? NSNumber, !isBoolean(raw) else {
            throw RemoteSamplingResponseError()
        }
        let rate = number.doubleValue
        guard rate >= 0, rate <= 100 else {
            throw RemoteSamplingResponseError()
        }
        return SampleRate(rate)
    }

    /// Custom values are delivered to the host application as the raw JSON object they arrived in.
    private static func readCustom(_ root: [String: Any]) throws -> String? {
        guard let dictionary = try readDictionary(root, key: Contract.custom) else {
            return nil
        }
        guard JSONSerialization.isValidJSONObject(dictionary),
              let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            throw RemoteSamplingResponseError()
        }
        return string
    }

    /// `JSONSerialization` bridges JSON booleans to `NSNumber`, so a type check needs care.
    private static func isBoolean(_ value: Any) -> Bool {
        CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
    }
}

/// Persists the last good snapshot on disk, so the first sessions after a cold start draw with
/// the values the console provided on a previous launch instead of the ones the app was built with.
///
/// The storage key names only what would make one entry the wrong answer for another — see
/// `key(source:context:)` for what that is and, just as importantly, what it is not. Entries
/// another key cannot see are never read, and are removed on the next load.
internal struct RemoteSamplingSnapshotStore {
    /// Bumped when the persisted layout changes, so old entries are left behind instead of misread.
    private static let cacheFormatVersion = "cfv1"
    /// Subdirectory of the core directory the snapshots live in.
    private static let subdirectory = "remote-config"

    private let directory: Directory

    init(coreDirectory: CoreDirectory) throws {
        self.directory = try coreDirectory.coreDirectory.createSubdirectory(path: Self.subdirectory)
    }

    /// Builds the storage key for the given source and application context.
    ///
    /// Only what this directory does not already separate, and only what changes the answer.
    ///
    /// The directory is `sha256(instanceName + site)` inside the application's own container, so
    /// the SDK instance, the site and the application itself are settled before a key is asked
    /// for — which is why neither the bundle identifier nor the service name appears here. Two
    /// applications on one device cannot reach each other's container at all.
    ///
    /// What is left is what the server's answer actually depends on: which host it came from, and
    /// the environment it was matched on. The address matters only when the application points the
    /// SDK at its own intake, because then the site in the directory says nothing about where the
    /// configuration came from.
    ///
    /// The application version is deliberately absent, though the server does match on it. Keying
    /// by it would mean the first session after every release draws at the value the app was built
    /// with — which can be an order of magnitude away from what the console set — to protect
    /// against a version-targeted rule that would at worst leave that session on the previous
    /// release's settings, and only until the next fetch. The web SDK does key by version, because
    /// two releases of a site are served at the same time and would overwrite each other's entry;
    /// an installed application is only ever one version, so that reason does not carry over.
    static func key(source: RemoteSamplingSource, context: DatadogContext) -> String {
        let material = [
            cacheFormatVersion,
            source.configurationURL.host ?? "",
            source.configurationURL.port.map { String($0) } ?? "",
            context.env
        ].joined(separator: "|")
        return sha256(material)
    }

    func load(forKey key: String) -> RemoteSamplingSnapshot? {
        // An environment switch, or a move to a different intake, strands the entry written under
        // the previous one. Nothing else ever collects them — the core's own retention only knows
        // about the directories it writes — so the launch that stops being able to read an entry
        // is the launch that removes it.
        prune(keeping: key)

        let url = fileURL(forKey: key)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(RemoteSamplingSnapshot.self, from: data)
    }

    func save(_ snapshot: RemoteSamplingSnapshot, forKey key: String) {
        guard let data = try? JSONEncoder().encode(snapshot) else {
            return
        }
        try? data.write(to: fileURL(forKey: key), options: .atomic)
    }

    /// Removes every entry but the one this configuration can still read.
    ///
    /// Best effort throughout: a file that will not go stays, and is retried on the next launch.
    /// Failing to tidy up is never a reason to fail the load it runs before.
    private func prune(keeping key: String) {
        guard let files = try? directory.files() else {
            return
        }
        for file in files where file.name != key {
            try? file.delete()
        }
    }

    private func fileURL(forKey key: String) -> URL {
        directory.url.appendingPathComponent(key)
    }
}
