/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import DatadogInternal
import Foundation

/// The configuration a RUM session was drawn with, fixed for the session's life.
///
/// Sessions never flip: the draw happens once, at session creation, from the remote rates the core
/// last published (falling back to the value the app was initialised with when the console set
/// none), and the record below is what view events report.
internal struct RUMDrawnConfiguration: Equatable {
    /// The session sample rate the session was drawn with — remote when set, init otherwise.
    let sessionSampleRate: SampleRate
    /// The console configuration version the session was drawn with (`rc_version`); 0 when no
    /// remote configuration was in effect.
    let version: Int64

    /// Records the draw that just happened.
    ///
    /// `nil` only when there is nothing to record — no configuration was in effect and the draw
    /// used the value the app was initialised with, so events reporting that value are already
    /// telling the truth, exactly as before remote configuration existed.
    ///
    /// A `beforeSampling` hook is reason enough on its own: it applies whether or not the console
    /// is publishing anything, so an app that only uses the hook still draws at a rate that is not
    /// the init value, and without a record every event would report the init value instead of the
    /// rate that actually decided the session.
    ///
    /// - Parameters:
    ///   - configurationVersion: the console configuration the draw used, or nil when none was in
    ///     effect — and also when the session was forced, because forcing decided it instead.
    ///   - drawnSessionSampleRate: the rate the draw actually used — the console's, the init value,
    ///     or whatever `beforeSampling` returned. It is what the events report, because it is what
    ///     decided the session.
    ///   - initialSessionSampleRate: the value the app was initialised with, to tell "nothing
    ///     happened" from "the draw moved".
    init?(configurationVersion: Int64?, drawnSessionSampleRate: SampleRate, initialSessionSampleRate: SampleRate) {
        guard configurationVersion != nil || drawnSessionSampleRate != initialSessionSampleRate else {
            return nil
        }
        self.sessionSampleRate = drawnSessionSampleRate
        self.version = configurationVersion ?? 0
    }

    /// The rate a new session is drawn at: the console's where it published one, the init value
    /// otherwise, with the host application's hook having the final say. And whether a session
    /// the rate leaves out is kept in case it reports an error, in the same order.
    ///
    /// Every draw of a new session goes through here: the session scope, and the session RUM
    /// creates on the next launch for a crash that had none of its own.
    static func resolveSampling(
        remoteRates: RemoteSamplingRates?,
        initialSessionSampleRate: SampleRate,
        sessionOnError initialSessionOnError: Bool,
        beforeSampling: BeforeSamplingCallback?,
        telemetry: Telemetry
    ) -> (rate: SampleRate, sessionOnError: Bool) {
        let base = remoteRates?.sessionSampleRate ?? initialSessionSampleRate
        let sessionOnError = remoteRates?.sessionOnError ?? initialSessionOnError
        guard let hook = beforeSampling else {
            return (base, sessionOnError)
        }
        let custom = remoteRates?.custom
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) }
            .flatMap { $0 as? [String: Any] }
        guard let override = hook(BeforeSamplingContext(sessionSampleRate: base, custom: custom)) else {
            return (base, sessionOnError)
        }
        // A rate we cannot trust is not a rate to sample a customer's traffic with, and a mistake
        // in the host application must never take their collection down with it.
        guard override >= 0, override <= 100 else {
            telemetry.error("beforeSampling returned \(override), which is not a rate; drawing at \(base) instead")
            return (base, sessionOnError)
        }
        // The hook's documented contract is "0 never collects". A session it draws at 0 must not
        // be kept by the on-error switch either, or "never" would quietly become "on error".
        return (override, sessionOnError && override != 0)
    }
}

/// Builds the URL the core asks for the remote sampling configuration.
///
/// A custom endpoint means the app was pointed at the customer's own host for the RUM intake, and
/// the configuration lives beside it there — which is exactly the layout the private-deployment
/// nginx template serves.
///
/// `sdk` carries `context.source`, not the literal `"ios"`: a cross-platform wrapper sets that
/// field to its own name (`react-native`, `flutter`, …) and only falls back to `"ios"` for a
/// native app, so a rule targeting the wrapper matches the runtime the app actually is. It also
/// keeps the pair honest — `sdk_version` already reports the wrapper's version, so a literal here
/// would describe one request as two different SDKs.
internal func remoteSamplingConfigurationURL(customEndpoint: URL?, context: DatadogContext) -> URL? {
    let intake = customEndpoint ?? context.site.endpoint.appendingPathComponent("api/v2/rum")
    var components = URLComponents(url: intake.appendingPathComponent("config"), resolvingAgainstBaseURL: false)
    components?.queryItems = [
        URLQueryItem(name: "client_token", value: context.clientToken),
        URLQueryItem(name: "sdk", value: context.source),
        URLQueryItem(name: "sdk_version", value: context.sdkVersion),
        URLQueryItem(name: "env", value: context.env),
        URLQueryItem(name: "app_version", value: context.version)
    ]
    return components?.url
}
