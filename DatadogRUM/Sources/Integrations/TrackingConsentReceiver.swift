/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation
import DatadogInternal

/// FLASHCAT FORK - tells RUM when tracking consent is withdrawn.
///
/// An ordinary session needs no telling: its writer drops what it assembles from then on, and
/// what it wrote before stays written. A session kept on error holds its events in memory, and
/// what it holds must not follow a later error out once consent is granted again. The session
/// cannot notice the withdrawal on its own: no RUM command need arrive between the withdrawal and
/// the next grant.
internal final class TrackingConsentReceiver: FeatureMessageReceiver {
    private let monitor: Monitor
    private var trackingConsent: TrackingConsent?

    init(monitor: Monitor) {
        self.monitor = monitor
    }

    func receive(message: FeatureMessage, from core: DatadogCoreProtocol) -> Bool {
        guard case .context(let context) = message else {
            return false
        }
        let withdrawn = context.trackingConsent == .notGranted && trackingConsent != .notGranted
        trackingConsent = context.trackingConsent
        if withdrawn {
            monitor.discardWithheldEvents()
        }
        return false // context updates are broadcast; claiming them would only suppress the fallback
    }
}
