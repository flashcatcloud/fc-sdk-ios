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
    let received: Int
}

extension RemoteSamplingResponse {
    /// Reads a configuration response body.
    ///
    /// The contract is a flat JSON object. Keys the SDK does not know are ignored, so an older SDK
    /// can talk to a newer console. What is NOT ignored is the envelope — `schema_version`,
    /// `version`, `enabled` and the shape of `rum` — because that is the only thing separating a
    /// configuration from any other JSON object that happens to carry a number. See
    /// `checkSchemaVersion` for why getting that wrong is not merely a wasted request.
    ///
    /// Inside a valid envelope the reading is per-field: a knob this SDK cannot use is dropped and
    /// the rest of the response still applies, which is what the web and Android SDKs do.
    ///
    /// - Parameters:
    ///   - body: The response body.
    ///   - etag: The validator the server stamped this body with, or nil when it sent none —
    ///     the next request then simply asks unconditionally.
    static func parse(body: Data, etag: String?, telemetry: Telemetry = NOPTelemetry()) throws -> RemoteSamplingResponse {
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
        let enabled = try readEnabled(root)
        // Read here rather than inside the branch below so its SHAPE is checked even when the kill
        // switch is off and its contents are deliberately not used: a body whose `rum` is not an
        // object is not a configuration response, and must not be allowed to set the version floor.
        let rum = try readDictionary(root, key: Contract.rum) ?? [:]
        let activation = readActivation(root, telemetry: telemetry)

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

        return RemoteSamplingResponse(
            snapshot: RemoteSamplingSnapshot(
                version: version,
                etag: etag,
                enabled: true,
                sessionSampleRate: readRate(rum, key: Contract.sessionSampleRate),
                custom: readCustom(root)
            ),
            activation: activation
        )
    }

    // MARK: - Whitelisted readers

    /// The contract this SDK reads. Not the SDK version and not the settings version: it names the
    /// SHAPE of the body, and the server bumps it only when a body would be misread by a reader
    /// written against the previous shape.
    static let supportedSchemaVersion = 1

    /// The stamp the server writes on every configuration response, and the first thing read.
    ///
    /// Required, and required to be a number. An absent stamp used to be read as "a server that
    /// predates the field", but no such server exists: this endpoint has stamped every response
    /// since it existed. What accepting an unstamped body costs is severe and permanent. Strip the
    /// stamp and the only thing left telling a configuration apart from any other JSON object is a
    /// numeric `version` — which a captive portal, a misrouted proxy, or a private deployment
    /// whose `/config` route lands on some other service can all supply. Taking one of those for a
    /// configuration empties every knob, persists whatever number it carried, and then refuses
    /// every genuine answer beneath it, the console's own repair included: `version` is a floor
    /// that only ever moves forward. Nothing short of a reinstall or an environment switch clears
    /// it. The web SDK reads the field this way, and for this reason.
    ///
    /// The two refusals are kept apart because they deserve opposite answers. A body we cannot
    /// recognise as a configuration at all is worth asking again for — the next answer may come
    /// from the real endpoint. A stamp we can read and do not know is an answered question, and
    /// asking again would fetch the same refusal.
    private static func checkSchemaVersion(_ root: [String: Any]) throws {
        guard let raw = root[Contract.schemaVersion], let number = raw as? NSNumber, !isBoolean(raw) else {
            throw RemoteSamplingResponseError()
        }
        guard number.intValue == supportedSchemaVersion else {
            throw RemoteSamplingUnsupportedSchemaError(received: number.intValue)
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

    /// The console's publish counter, so anything that is not a whole, non-negative number cannot
    /// be one.
    ///
    /// Checked this strictly because a version is the one value that can refuse a later answer: an
    /// implausible one does not merely go unused, it freezes the settings stored beside it. The
    /// upper bound is the largest integer a JSON number survives a round trip at — the same one the
    /// web SDK uses — and a fractional value is refused rather than truncated, because a counter
    /// that arrives as `1.5` did not come from the console.
    private static func readVersion(_ root: [String: Any]) throws -> Int64 {
        guard let raw = root[Contract.version], let number = raw as? NSNumber, !isBoolean(raw) else {
            throw RemoteSamplingResponseError() // a configuration without a version cannot be reported back
        }
        let value = number.doubleValue
        guard value >= 0, value <= 9_007_199_254_740_991, value.rounded(.towardZero) == value else {
            throw RemoteSamplingResponseError()
        }
        return number.int64Value
    }

    /// The kill switch, required and required to be a boolean.
    ///
    /// Absent used to read as `false`, which meant any object that merely lacked the field asked
    /// this client to drop every knob it had — and, with the version stored beside it, to keep
    /// refusing the answers that would have put them back. Part of the envelope for that reason:
    /// see `checkSchemaVersion`.
    private static func readEnabled(_ root: [String: Any]) throws -> Bool {
        guard let raw = root[Contract.enabled], let number = raw as? NSNumber, isBoolean(raw) else {
            throw RemoteSamplingResponseError()
        }
        return number.boolValue
    }

    /// How the console wants the change applied — and never a reason to refuse the change itself.
    ///
    /// Everything else here refuses a body it cannot read, because a half-applied configuration is
    /// worse than none. This field is the exception, and it has to be: the whole point of reading
    /// by whitelist is that an older SDK can still talk to a newer console, and an activation mode
    /// this SDK has not heard of is exactly that case. Refusing on it would mean the day the server
    /// learns a third way to apply a change, every client on this version stops accepting any
    /// configuration at all — rates included, which have nothing to do with it. Falling back to the
    /// conservative mode leaves the running session alone, which is the safe way to read an
    /// instruction we cannot follow.
    private static func readActivation(_ root: [String: Any], telemetry: Telemetry) -> RemoteSamplingActivation {
        guard let raw = root[Contract.activation] else {
            return .nextSession
        }
        guard let string = raw as? String, let activation = RemoteSamplingActivation(rawValue: string) else {
            telemetry.debug(
                "Remote sampling: this SDK does not read the activation the console asked for; " +
                "applying the configuration to new sessions and leaving the running one alone"
            )
            return .nextSession
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
    ///
    /// So does one this SDK cannot use — the wrong type, or outside 0...100. Never clamped: a rate
    /// we cannot trust is not a rate to sample a customer's traffic with. But the single field is
    /// dropped rather than the whole response, which is what the web and Android SDKs do, and the
    /// reason is that refusing the response lets one damaged knob take the version and the custom
    /// values down with it — and, because the version is a floor, keep them down.
    private static func readRate(_ rum: [String: Any], key: String) -> SampleRate? {
        guard let raw = rum[key], let number = raw as? NSNumber, !isBoolean(raw) else {
            return nil
        }
        let rate = number.doubleValue
        guard rate >= 0, rate <= 100 else {
            return nil
        }
        return SampleRate(rate)
    }

    /// Custom values are delivered to the host application as the raw JSON object they arrived in.
    ///
    /// The application's own bag is not part of what makes a body a configuration, so one that is
    /// not a keyed object is dropped and the knobs beside it still apply: a mistake at the
    /// application's level must not switch the platform's settings back off.
    private static func readCustom(_ root: [String: Any]) -> String? {
        guard let dictionary = root[Contract.custom] as? [String: Any],
              JSONSerialization.isValidJSONObject(dictionary),
              let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return nil
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
    /// What is left is what the server's answer actually depends on: which host it came from, which
    /// application it was asked for, and the environment it was matched on. The address matters
    /// only when the application points the SDK at its own intake, because then the site in the
    /// directory says nothing about where the configuration came from.
    ///
    /// The client token names the application, and leaving it out is not the small mistake it
    /// looks like. Versions are counted per application and only ever climb, so an entry written
    /// for one application is not merely wrong for another — it is AHEAD of it. The guard that
    /// refuses a configuration older than the one in force would then refuse every answer the new
    /// application gives until its own version passes the old one, and the wrong rates would hold
    /// for as long as that takes. The token is hashed with the rest and never lands on disk in
    /// clear.
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
            context.clientToken,
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
