/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation
import DatadogInternal

/// A type managing RUM information necessary for building context of fatal errors such as Crashes or Fatal App Hangs.
internal protocol FatalErrorContextNotifying: AnyObject {
    /// The state of the current RUM session.
    /// Can be `nil` if no session was yet started. Never gets `nil` after starting first session.
    var sessionState: RUMSessionState? { set get }
    /// The active RUM view in current session.
    /// Can be `nil` if no view is yet started. Will become `nil` if view was stopped without starting the new one.
    var view: RUMViewEvent? { set get }
    /// The current set of RUM attributes.
    /// It gets updated with global attributes being added or removed in `RUMMonitor`.
    var globalAttributes: [String: Encodable] { set get }
}

/// Manages RUM information necessary for building context of fatal errors such as Crashes or Fatal App Hangs.
/// It shares every change in the core context as `RUMFatalErrorContext`, read by Crash Reporting.
internal final class FatalErrorContextNotifier: FatalErrorContextNotifying {
    /// The scope to share the fatal error context through.
    private let featureScope: FeatureScope

    /// The current value, replaced by a new instance on every change.
    @ReadWriteLock
    private var context = RUMFatalErrorContext(sessionState: nil, view: nil, globalAttributes: nil)

    init(featureScope: FeatureScope) {
        self.featureScope = featureScope
    }

    /// The state of the current RUM session.
    /// Can be `nil` if no session was yet started. Never gets `nil` after starting first session.
    var sessionState: RUMSessionState? {
        get { context.sessionState }
        set { update { RUMFatalErrorContext(sessionState: newValue, view: $0.view, globalAttributes: $0.globalAttributes) } }
    }

    /// The active RUM view in current session.
    /// Can be `nil` if no view is yet started. Will become `nil` if view was stopped without starting the new one.
    var view: RUMViewEvent? {
        get { context.view }
        set { update { RUMFatalErrorContext(sessionState: $0.sessionState, view: newValue, globalAttributes: $0.globalAttributes) } }
    }

    var globalAttributes: [String: Encodable] {
        get { context.globalAttributes?.contextInfo ?? [:] }
        set {
            update {
                RUMFatalErrorContext(
                    sessionState: $0.sessionState,
                    view: $0.view,
                    globalAttributes: RUMEventAttributes(contextInfo: newValue)
                )
            }
        }
    }

    private func update(_ change: (RUMFatalErrorContext) -> RUMFatalErrorContext) {
        _context.mutate { $0 = change($0) }
        // The value is read when the core context is written, on its queue: whatever order the writes
        // requested from different threads run in, the last one sets the latest value.
        featureScope.set(context: { [weak self] in self?.context })
    }
}
