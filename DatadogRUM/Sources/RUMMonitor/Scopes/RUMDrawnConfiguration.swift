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
    /// `nil` when no remote configuration is in effect at all: events then report the init values,
    /// exactly as before remote configuration existed.
    ///
    /// - Parameters:
    ///   - rates: what the console had published at the moment of the draw.
    ///   - drawnSessionSampleRate: the rate the draw actually used — the console's, the init value,
    ///     or whatever `beforeSampling` returned. It is what the events report, because it is what
    ///     decided the session.
    init?(rates: RemoteSamplingRates?, drawnSessionSampleRate: SampleRate) {
        guard let rates = rates else {
            return nil
        }
        self.sessionSampleRate = drawnSessionSampleRate
        self.version = rates.version
    }
}

/// Builds the URL the core asks for the remote sampling configuration.
///
/// A custom endpoint means the app was pointed at the customer's own host for the RUM intake, and
/// the configuration lives beside it there — which is exactly the layout the private-deployment
/// nginx template serves.
internal func remoteSamplingConfigurationURL(customEndpoint: URL?, context: DatadogContext) -> URL? {
    let intake = customEndpoint ?? context.site.endpoint.appendingPathComponent("api/v2/rum")
    var components = URLComponents(url: intake.appendingPathComponent("config"), resolvingAgainstBaseURL: false)
    components?.queryItems = [
        URLQueryItem(name: "client_token", value: context.clientToken),
        URLQueryItem(name: "sdk", value: "ios"),
        URLQueryItem(name: "sdk_version", value: context.sdkVersion),
        URLQueryItem(name: "env", value: context.env),
        URLQueryItem(name: "app_version", value: context.version)
    ]
    return components?.url
}
