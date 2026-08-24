/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation

/// Where to ask for the sampling rates set in the Flashcat console.
///
/// RUM publishes this when the app opts in, because the address depends on RUM's own endpoint
/// configuration, which the core does not otherwise know. Its presence is also what tells the core
/// there is anything to ask for: with no source published, nothing is fetched and nothing changes.
public struct RemoteSamplingSource: AdditionalContext, Equatable {
    public static let key = "remote-sampling-source"

    /// The full configuration URL, including the query the server matches rules on.
    public let configurationURL: URL

    public init(configurationURL: URL) {
        self.configurationURL = configurationURL
    }
}

/// The configuration values the console last provided.
///
/// The core is the only writer; RUM and Session Replay read it to decide whether to keep a session
/// and whether to record it. A knob is absent — never zero — when the console did not set it, and
/// the feature then keeps the value the app was initialised with. Reporting a zero we invented
/// would silently stop collection nobody asked to stop.
public struct RemoteSamplingRates: AdditionalContext, Equatable {
    public static let key = "remote-sampling-rates"

    public let sessionSampleRate: SampleRate?

    /// The version of the console configuration these values came from.
    ///
    /// It survives the kill switch: when the console disables remote configuration the values are
    /// cleared but the version is kept, so the client can still report which version it runs.
    /// `0` means the console never provided a configuration.
    public let version: Int64

    /// The console's custom values, as the raw JSON object they were delivered in.
    ///
    /// Delivery is the platform's job; the meaning belongs to the host application, which reads
    /// them through `RUMMonitorProtocol.getRemoteConfig()`. Kept as raw JSON so any value shape the
    /// console adds later reaches the app without an SDK update.
    public let custom: String?

    public init(
        sessionSampleRate: SampleRate?,
        version: Int64 = 0,
        custom: String? = nil
    ) {
        self.sessionSampleRate = sessionSampleRate
        self.version = version
        self.custom = custom
    }
}

/// Sent by the core when the console asked for a change to take effect immediately and the rates
/// this app will now draw with really changed.
///
/// RUM answers it by ending the running session so a new one starts under the new rates. Ending and
/// restarting is deliberate: a session that was not being collected has no id and no history, so
/// flipping its decision in place would invent a session that appears to begin mid-use, and a
/// collected session flipped off would simply stop, looking like it ended early.
public struct RemoteSamplingChangedMessage {
    public init() {}
}
