/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import DatadogInternal
import Foundation

/// Receives the core's remote-sampling signals for the RUM feature.
///
/// Two kinds of messages matter here:
/// - `RemoteSamplingChangedMessage`, sent when the console asked for an immediate change to the
///   rates this app draws with. RUM answers by ending the running session, so the next one starts
///   under the new rates. Ending and restarting is deliberate: a session that was not being
///   collected has no id and no history, so flipping its decision in place would invent a session
///   that appears to begin mid-use, and a collected session flipped off would simply stop, looking
///   like it ended early. A forced session is left alone — see `RUMApplicationScope`.
/// - context updates, which carry the console's custom values for the host application to read
///   through `RUMMonitorProtocol.getRemoteConfig()`.
internal struct RemoteSamplingReceiver: FeatureMessageReceiver {
    let monitor: Monitor

    func receive(message: FeatureMessage, from core: DatadogCoreProtocol) -> Bool {
        switch message {
        case .payload(is RemoteSamplingChangedMessage):
            monitor.notifyRemoteSamplingChanged()
            return true
        case .context(let context):
            monitor.remoteConfigCustom = context.additionalContext(ofType: RemoteSamplingRates.self)?.custom
            return false // context updates are broadcast; claiming them would only suppress the fallback
        default:
            return false
        }
    }
}
