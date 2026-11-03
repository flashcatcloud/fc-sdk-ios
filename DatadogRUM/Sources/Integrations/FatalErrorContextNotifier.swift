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
    private struct State {
        /// The current value, replaced by a new instance on every change.
        var context = RUMFatalErrorContext(sessionState: nil, view: nil, globalAttributes: nil)
        /// Whether a write to the core context is requested and has not read `context` yet: changes made meanwhile
        /// are written by it, without requesting another.
        var isWritePending = false
    }

    /// The scope to share the fatal error context through.
    private let featureScope: FeatureScope

    @ReadWriteLock
    private var state = State()

    private var context: RUMFatalErrorContext { state.context }

    init(featureScope: FeatureScope) {
        self.featureScope = featureScope
    }

    /// The state of the current RUM session.
    /// Can be `nil` if no session was yet started. Never gets `nil` after starting first session.
    var sessionState: RUMSessionState? {
        get { context.sessionState }
        set {
            update { current in
                current.sessionState == newValue ? nil : RUMFatalErrorContext(sessionState: newValue, view: current.view, globalAttributes: current.globalAttributes)
            }
        }
    }

    /// The active RUM view in current session.
    /// Can be `nil` if no view is yet started. Will become `nil` if view was stopped without starting the new one.
    var view: RUMViewEvent? {
        get { context.view }
        set {
            update { current in
                newValue == nil && current.view == nil ? nil : RUMFatalErrorContext(sessionState: current.sessionState, view: newValue, globalAttributes: current.globalAttributes)
            }
        }
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

    /// - Parameter change: the new value, or `nil` if it would not change.
    private func update(_ change: (RUMFatalErrorContext) -> RUMFatalErrorContext?) {
        var requestsWrite = false
        _state.mutate { state in
            guard let changed = change(state.context) else {
                return
            }
            state.context = changed
            requestsWrite = !state.isWritePending
            state.isWritePending = true
        }
        guard requestsWrite else {
            return
        }
        // The value is read when the core context is written, on its queue: a change made before that is written
        // by this write, and one made after requests the next. A request the core drops without running it (e.g.
        // once it is stopped or released) ends the pending write too, so later changes are not held back by it.
        let request = WriteRequest { [weak self] in
            self?._state.mutate { $0.isWritePending = false }
        }
        featureScope.set(context: { [weak self] in
            request.didRun = true
            var context: RUMFatalErrorContext?
            self?._state.mutate { state in
                state.isWritePending = false
                context = state.context
            }
            return context
        })
    }
}

/// A requested write of the core context, which calls `onDrop` if it is released without having run.
private final class WriteRequest {
    var didRun = false
    private let onDrop: () -> Void

    init(onDrop: @escaping () -> Void) {
        self.onDrop = onDrop
    }

    deinit {
        if !didRun {
            onDrop()
        }
    }
}
