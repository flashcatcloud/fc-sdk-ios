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
/// The core is the only writer and RUM the only reader: it draws each new session against these
/// values. Session Replay is not a reader — it samples with the rate the app configured and follows
/// RUM's decision about the session — so a replay rate is not delivered on this fork. A knob is
/// absent — never zero — when the console did not set it, and the feature then keeps the value the
/// app was initialised with. Reporting a zero we invented would silently stop collection nobody
/// asked to stop.
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

/// Synchronous access to the remote sampling configuration a previous launch stored.
///
/// The session draw is synchronous; the context that carries these rates to features is not. A
/// value published onto the context queue becomes visible some time AFTER the draw that needed it,
/// so a feature reading only the context would draw the first session of every launch under the
/// values the app was built with, and take the console's setting from the second session on. That
/// is precisely the case the on-disk snapshot exists to cover, so it has to be readable without a
/// queue hop.
public protocol RemoteSamplingReader: AnyObject {
    /// Loads what a previous launch stored, without waiting on any queue, so the first draw of
    /// this launch already sees it. The load happens once; later calls are cheap.
    ///
    /// - Parameter source: builds the address to load for from the context, which the core reads
    ///   synchronously. Returning nil means there is nothing to load.
    /// - Returns: the rates now in effect, or nil when nothing was stored.
    @discardableResult
    func primeRemoteSampling(source: (DatadogContext) -> RemoteSamplingSource?) -> RemoteSamplingRates?

    /// The rates in effect right now, readable synchronously.
    var remoteSamplingRates: RemoteSamplingRates? { get }
}
