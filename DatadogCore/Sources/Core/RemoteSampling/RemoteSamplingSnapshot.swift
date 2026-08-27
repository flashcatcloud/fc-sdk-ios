/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import CommonCrypto
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
    /// How the console wants the configuration to take effect.
    enum Activation: String, Equatable {
        /// New sessions draw with the new values; the running session is untouched.
        case nextSession = "next_session"
        /// The running session ends so the next one starts under the new values.
        case immediate = "immediate"
    }

    let snapshot: RemoteSamplingSnapshot
    let activation: Activation
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
    ///   - etag: The validator computed from the body by the caller.
    static func parse(body: Data, etag: String) throws -> RemoteSamplingResponse {
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
        guard let raw = root[Contract.schemaVersion] else {
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

    private static func readActivation(_ root: [String: Any]) throws -> Activation {
        guard let raw = root[Contract.activation] else {
            return .nextSession
        }
        guard let string = raw as? String, let activation = Activation(rawValue: string) else {
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

/// Computes the validator of a configuration response body: the first 16 hex characters of its
/// SHA-256, quoted, as the contract fixes it. Sent back as `If-None-Match`; the server answers
/// `304` when the body would be identical.
internal func remoteSamplingETag(for body: Data) -> String {
    var digest: [UInt8] = Array(repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    _ = body.withUnsafeBytes { CC_SHA256($0.baseAddress, UInt32(body.count), &digest) }
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return "\"\(hex.prefix(16))\""
}

/// Persists the last good snapshot on disk, so the first sessions after a cold start draw with
/// the values the console provided on a previous launch instead of the ones the app was built with.
///
/// The storage key embeds everything that makes a configuration entry invalid for another
/// configuration: a cache-format version (bumped when the layout changes), the endpoint host, the
/// application (service and bundle id), the environment and the application version. The SDK
/// version is deliberately not part of it — an SDK update must not throw away the console's
/// answer. Entries another key cannot see are simply never read.
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
    static func key(source: RemoteSamplingSource, context: DatadogContext) -> String {
        let material = [
            cacheFormatVersion,
            source.configurationURL.host ?? "",
            source.configurationURL.port.map { String($0) } ?? "",
            context.service,
            context.applicationBundleIdentifier,
            context.env,
            context.version
        ].joined(separator: "|")
        return sha256(material)
    }

    func load(forKey key: String) -> RemoteSamplingSnapshot? {
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

    private func fileURL(forKey key: String) -> URL {
        directory.url.appendingPathComponent(key)
    }
}
