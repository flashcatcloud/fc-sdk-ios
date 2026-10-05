/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

#if os(iOS)
import Foundation
import DatadogInternal

/// An observer notifying on`RUMContext` changes.
internal protocol RUMContextObserver {
    /// Starts notifying on distinct changes to `RUMContext`.
    ///
    /// - Parameters:
    ///   - queue: a queue to call `notify` block on
    ///   - notify: a closure receiving new `RUMContext` or `nil` if current RUM session is not sampled,
    ///     and the tracking consent in force. FLASHCAT FORK - the consent is read along with the
    ///     context because a replay withheld until its session errors must not hold what was
    ///     recorded without it.
    func observe(on queue: Queue, notify: @escaping (RUMCoreContext?, TrackingConsent) -> Void)
}

/// Receives RUM context from `DatadogCore` and notifies it through `RUMContextObserver` interface.
internal class RUMContextReceiver: FeatureMessageReceiver, RUMContextObserver {
    /// Notifies new `RUMContext` or `nil` if current RUM session is not sampled.
    private var onNew: ((RUMCoreContext?, TrackingConsent) -> Void)?
    private var previous: RUMCoreContext?
    private var previousConsent: TrackingConsent?

    // MARK: - FeatureMessageReceiver

    func receive(message: FeatureMessage, from core: DatadogCoreProtocol) -> Bool {
        guard case let .context(context) = message else {
            return false
        }

        let new = context.additionalContext(ofType: RUMCoreContext.self)
        let consent = context.trackingConsent

        // Notify only if it has changed. A change of consent alone matters only to a replay, and
        // there is none without a RUM context: notifying then would only re-run a draw for a
        // session that does not exist.
        if new != previous || (new != nil && consent != previousConsent) {
            onNew?(new, consent)
            previous = new
            previousConsent = consent
        }

        return true
    }

    // MARK: - RUMContextObserver

    func observe(on queue: Queue, notify: @escaping (RUMCoreContext?, TrackingConsent) -> Void) {
        onNew = { new, consent in
            queue.run {
                notify(new, consent)
            }
        }
    }
}

#endif
