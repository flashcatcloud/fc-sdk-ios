/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import DatadogInternal
import Foundation

internal class RUMApplicationScope: RUMScope, RUMContextProvider {
    /// Tracks the overall application state since `RUM.enable()` was called.
    ///
    /// FLASHCAT FORK - readable rather than `private`, so a test can pin what an SDK-initiated
    /// session end does NOT record here. Its flags switch off the handling of events that arrive
    /// with no active view, and they belong to the application asking to stop collecting.
    let applicationState = RUMApplicationState()

    // MARK: - Child Scopes

    // Whether the application is already active. Set to true
    // when the first session starts.
    private(set) var applicationActive = false

    /// Session scope. It gets created with the first event.
    /// Might be re-created later according to session duration constraints.
    private(set) var sessionScopes: [RUMSessionScope] = []

    /// FLASHCAT FORK - set through `RUMMonitorProtocol.setForcedSession()`, read at every draw from
    /// then on. Process-lifetime, like the debugging decision it represents: the host application
    /// decides again on each launch.
    private(set) var isForcedSession = false

    /// The last active foreground view from the previous session.
    /// Used to restore the view when a new session starts after `sessionStop()`.
    private var lastActiveView: RUMViewScope?

    /// The end reason from the last active session. Used as "start reason" for the new session.
    private var lastSessionEndReason: RUMSessionScope.EndReason?

    var activeSession: RUMSessionScope? {
        get { return sessionScopes.first(where: { $0.isActive }) }
    }

    // MARK: - Initialization

    /// Container bundling dependencies for this scope.
    let dependencies: RUMScopeDependencies

    /// Handles resolution of `launchReason` during the app launch window (used primarily on tvOS and as a fallback on iOS).
    /// Buffers early RUM commands until the launch reason can be determined, then injects the resolved value and forwards them.
    let launchReasonResolver = LaunchReasonResolver(launchWindowThreshold: LaunchReasonResolver.Constants.launchWindowThreshold)
    /// Ensures the fallback to `launchReasonResolver` is logged only once when `launchReason` is unexpectedly `.uncertain` on iOS.
    private var didLogFallbackToResolver = false

    init(dependencies: RUMScopeDependencies) {
        self.dependencies = dependencies

        self.context = RUMContext(
            rumApplicationID: dependencies.rumApplicationID,
            sessionID: .nullUUID,
            isSessionActive: false,
            activeViewID: nil,
            activeViewPath: nil,
            activeViewName: nil,
            activeUserActionID: nil
        )
    }

    // MARK: - RUMContextProvider

    let context: RUMContext
    var attributes: [AttributeKey: AttributeValue] { [:] }

    // MARK: - RUMScope

    /// Entry point for processing a RUM command in the Application Scope.
    ///
    /// On iOS, we expect the `launchReason` to be resolved at SDK initialization using `task_role` or the prewarm flag.
    /// As a safeguard, we fall back to the `LaunchReasonResolver` if the `launchReason` is still `.uncertain`—
    /// in case the iOS-side assumptions fail (e.g., unhandled platform edge case or kernel API failure).
    ///
    /// On tvOS and watchOS, we always use the `LaunchReasonResolver`, since those platforms do not support
    /// `task_role` or prewarming signals.
    ///
    /// - Returns: `true` to indicate that the Application Scope should remain active.
    func process(command: RUMCommand, context: DatadogContext, writer: Writer) -> Bool {
        #if !os(tvOS) && !os(watchOS)
        guard context.launchInfo.launchReason != .uncertain else {
            if !didLogFallbackToResolver {
                dependencies.telemetry.debug("Falling back unexpectedly to 'launchReasonResolver' due to 'uncertain' launch reason")
                didLogFallbackToResolver = true
            }
            launchReasonResolver
                .deferUntilLaunchReasonResolved(command: command, context: context, writer: writer, onReady: _process(command:context:writer:))
            return true
        }
        _process(command: command, context: context, writer: writer)
        #else
        launchReasonResolver
            .deferUntilLaunchReasonResolved(command: command, context: context, writer: writer, onReady: _process(command:context:writer:))
        #endif

        return true
    }

    private func _process(command: RUMCommand, context: DatadogContext, writer: Writer) {
        if command is RUMSetForcedSessionCommand {
            // Set before any other handling, because this command can be the one that starts a
            // session: the flow below creates one whenever none is active, and a session drawn a
            // moment before the flag is set would be an ordinary session that has to be thrown
            // away and replaced, leaving a stopped session behind for no reason.
            isForcedSession = true
        }

        if let rateChange = command as? RUMRemoteSamplingChangedCommand {
            // Answered here, ahead of everything else, because this is a signal from the console
            // rather than something the visitor did: the flow below starts a session for any
            // command that finds none running, and a rate change must never be the reason a
            // session exists. Letting it start one would put a session on the record for every
            // idle app in the fleet each time somebody moves a slider — and would then end it
            // again, having drawn it under the very rates it was about to be re-drawn for.
            //
            // The stop below re-enters `_process`, which does the `lastActiveView` bookkeeping on
            // the way through, so returning early here costs the next session nothing.
            if shouldEndRunningSession(on: rateChange) {
                _process(
                    command: RUMStopSessionCommand(time: rateChange.time, isRequestedByApplication: false),
                    context: context,
                    writer: writer
                )
            }
            return
        }

        // `RUMSDKInitCommand` forces the creation of the initial session
        // Added in https://github.com/DataDog/dd-sdk-ios/pull/1278 to ensure that logs and traces
        // can be correlated with valid RUM session id (even if occurring before any user interaction).
        if command is RUMSDKInitCommand {
            createInitialSession(with: context, on: command)

            // RUM-6698: When the user launches an app that was not running (cold start), the expected
            // initial app state is `.inactive`:
            //
            // Ref.: https://developer.apple.com/documentation/uikit/app_and_environment/managing_your_app_s_life_cycle
            // > After launch, the system puts the app in the inactive or background state, depending on whether the UI
            // > is about to appear onscreen. When launching to the foreground, the system transitions the app to the
            // > active state automatically.
            //
            // However, for apps that initialize RUM after `application(_:didFinishLaunchingWithOptions:)`,
            // the initial state can be `.active`. Therefore, we consider both `.inactive` and `.active` as valid
            // initial states for starting the initial view.
            let appState = context.applicationStateHistory.currentState
            let sdkInitInForeground = appState == .inactive || appState == .active
            let isUserLaunch = context.launchInfo.launchReason == .userLaunch

            if sdkInitInForeground || isUserLaunch {
                // Start "ApplicationLaunch" view immediatelly:
                startApplicationLaunchView(on: command, context: context, writer: writer)
            }
            return
        }

        // If the application has not been yet activated and no sessions exist -> create the initial session
        // Added in https://github.com/DataDog/dd-sdk-ios/pull/1219 to start new session automatically when
        // a user action is sent (startView or addUserAction).
        if sessionScopes.isEmpty && !applicationActive {
            // This flow is likely stale code as`RUMSDKInitCommand` should already start the session before reaching this point
            dependencies.telemetry.debug("Starting initial session from lazy flow")
            createInitialSession(with: context, on: command)
        }

        // Create the application launch view on any command
        if !applicationActive {
            startApplicationLaunchView(on: command, context: context, writer: writer)
        }

        if activeSession == nil {
            // No active sessions, start a new one
            if !(command is RUMHandleAppLifecycleEventCommand) {
                startNewSession(on: command, context: context, writer: writer)
            }
        }

        // Store the last foreground view that was active before the session expired or was stopped.
        // This allows the next session to lazily restart the same view if needed.
        let lastActiveForegroundView = activeSession?.viewScopes.first(where: { $0.isActiveView && $0.viewPath != RUMOffViewEventsHandlingRule.Constants.backgroundViewURL })
        lastActiveView = lastActiveForegroundView ?? lastActiveView

        if let forced = command as? RUMSetForcedSessionCommand {
            // A session already being collected keeps running: RUM cannot retro-collect what a
            // running session already dropped, and cutting it in two would gain nothing. One that
            // was NOT collected ends now, so a collected one starts in its place. A session
            // started by this very command is already forced, so there is nothing to replace.
            if let activeSession = activeSession, !activeSession.isSampled {
                _process(
                    command: RUMStopSessionCommand(time: forced.time, isRequestedByApplication: false),
                    context: context,
                    writer: writer
                )
            }
            return
        }

        // Only a stop the host application asked for. A session the SDK ended itself, to draw the
        // next one under rates the console changed, is not the application saying "stop
        // collecting" — and this flag is read to decide whether to keep handling events that
        // arrive with no active view.
        if let stop = command as? RUMStopSessionCommand, stop.isRequestedByApplication {
            applicationState.wasAnySessionStopped = true
        }

        // Can't use scope(byPropagating:context:writer) because of the extra step in looking for sessions
        // that need a refresh
        sessionScopes = sessionScopes.compactMap({ scope in
            if scope.process(command: command, context: context, writer: writer) {
                // proccss(command:context:writer) returned true, so keep the scope around
                // as it it still has work to do.
                return scope
            }

            // proccss(command:context:writer) returned false, so the scope will be deallocated at the end of
            // this execution context. End the "RUM Session Ended" metric:
            defer { dependencies.sessionEndedMetric.endMetric(sessionID: scope.sessionUUID, with: context) }

            // proccss(command:context:writer) returned false, but if the scope is still active
            // it means the session reached one of the end reasons
            guard let endReason = scope.endReason else {
                // Sanity telemetry, we don't expect reaching this flow
                dependencies.telemetry.error("A session has ended with no 'end reason'")
                return nil
            }

            // Store "end reason" so it will be used as "start reason" for next session
            lastSessionEndReason = endReason

            switch endReason {
            case .timeOut, .maxDuration:
                applicationState.wasPreviousSessionStopped = false
                if !(command is RUMHandleAppLifecycleEventCommand) {
                    // Replace this session scope with the scope for refreshed session:
                    return refresh(expiredSession: scope, on: command, context: context, writer: writer)
                } else {
                    // The next session will start lazily on next event
                    return nil
                }
            case .stopAPI:
                // Remove this session scope (a new on will be started upon receiving user interaction):
                // Same distinction as above: a session the SDK ended to re-draw must not leave the
                // next one refusing off-view events. Defaults to the conservative answer if the end
                // reason ever arrives without the command that caused it.
                applicationState.wasPreviousSessionStopped =
                    (command as? RUMStopSessionCommand)?.isRequestedByApplication ?? true
                return nil
            }
        })

        // Sanity telemetry, only end up with one active session
        let activeSessions = sessionScopes.filter { $0.isActive }
        if activeSessions.count > 1 {
            dependencies.telemetry.error("An application has \(activeSessions.count) active sessions")
        }
    }

    // MARK: - Private

    /// FLASHCAT FORK - whether a change in the rates ends the session that is running.
    ///
    /// Two reasons, and they are not the same question.
    ///
    /// `immediate` is the console saying "apply this now". It carries no claim about what the new
    /// rates decide — only that the operator does not want to wait — so the session ends and the
    /// next one is drawn afresh, whatever the rates turn out to be.
    ///
    /// A rate of zero needs no such instruction, because it is the one value that answers the
    /// question on its own — in both directions. Moving TO zero says nothing is to be collected;
    /// moving AWAY from a session that was drawn at zero says this visitor was never in the draw
    /// at all and now could be. A session that is collecting right now
    /// would otherwise go on collecting until it happens to rotate, which can be hours away — and
    /// "stop collecting" is the one request where waiting hours is the wrong answer. Every other
    /// rate is silent on this session's fate: whether it "should" still be kept can only be
    /// answered by drawing again, and drawing twice is not the same as drawing once.
    ///
    /// The rate that counts is the one that would decide a session drawn now — the console's where
    /// it published one, the value the app was initialised with where it did not. The console can
    /// clear a knob as well as set it, and clearing it hands the decision back to the init value,
    /// which the core never sees. That is why this is answered here and not there.
    ///
    /// A forced session answers no to both. It is collected whatever the rates say, so ending it
    /// would only buy an identical forced session — the same session, cut in two, with the
    /// visitor's current view lost from the recording somebody turned forcing on to watch.
    private func shouldEndRunningSession(on command: RUMRemoteSamplingChangedCommand) -> Bool {
        guard let activeSession = activeSession, !isForcedSession else {
            return false
        }
        if command.activation == .immediate {
            return true
        }
        let rateNowInForce = dependencies.remoteSamplingRates()?.sessionSampleRate
            ?? dependencies.sessionSampler.samplingRate

        if rateNowInForce == 0 {
            // A session that is not being collected has nothing to stop, and ending it would only
            // put a stopped session on the record and leave its replacement reporting an explicit
            // stop.
            return activeSession.isSampled
        }

        // The other direction, and the reason it is written against the rate the session was DRAWN
        // at rather than against whether it is being collected.
        //
        // Re-drawing only the sessions that were not collected, while leaving the collected ones
        // alone, spares the winners and re-rolls the losers — a fleet drawn at 20 and moved to 50
        // would come out at 60, because the 20 that were already kept stay kept. A rate of 0 is the
        // one value with no winners to spare: nothing was collected, no coin was flipped, and
        // re-drawing everyone at the new rate lands exactly on it.
        //
        // What it buys is the case where the console is the only thing that ever turns collection
        // on. An application built at 0 shows the operator nothing at all until its sessions
        // happen to rotate, and nothing at all is indistinguishable from broken. What it costs is
        // nothing: a session drawn at 0 has no id, no events and no history — it does not exist in
        // the data, so there is no seam for ending it to leave.
        let rateItWasDrawnAt = activeSession.drawnConfiguration?.sessionSampleRate
            ?? dependencies.sessionSampler.samplingRate
        return rateItWasDrawnAt == 0
    }

    /// Sanity count to make sure initial session is created only once.
    private var didCreateInitialSessionCount = 0

    /// Starts initial RUM Session.
    private func createInitialSession(with context: DatadogContext, on command: RUMCommand) {
        if didCreateInitialSessionCount > 0 { // Sanity check
            dependencies.telemetry.error("Creating initial session \(didCreateInitialSessionCount) extra time(s) due to \(type(of: command)) (previous end reason: \(lastSessionEndReason?.rawValue ?? "unknown"))")
        }
        didCreateInitialSessionCount += 1

        var startPrecondition: RUMSessionPrecondition? = nil

        if context.applicationStateHistory.currentState == .background {
            switch context.launchInfo.launchReason {
            case .userLaunch:       startPrecondition = .userAppLaunch // UISceneDelegate-based apps always start in background
            case .backgroundLaunch: startPrecondition = .backgroundLaunch
            case .prewarming:       startPrecondition = .prewarm
            default:
                dependencies.telemetry.error("Creating initial session in background with unexpected launch reason: \(context.launchInfo.launchReason)")
            }
        } else {
            startPrecondition = .userAppLaunch
        }

        let initialSession = RUMSessionScope(
            isInitialSession: true,
            parent: self,
            startTime: context.sdkInitDate,
            startPrecondition: startPrecondition,
            context: context,
            dependencies: dependencies,
            applicationState: applicationState,
            isForced: isForcedSession
        )

        lastSessionEndReason = nil
        sessionScopes.append(initialSession)
        sessionScopeDidUpdate(initialSession)
    }

    /// Starts new RUM Session immediately after previous one expires or time outs. It transfers some of the state from the expired session to the new one.
    private func refresh(expiredSession: RUMSessionScope, on command: RUMCommand, context: DatadogContext, writer: Writer) -> RUMSessionScope {
        var startPrecondition: RUMSessionPrecondition? = nil

        if lastSessionEndReason == .timeOut {
            startPrecondition = .inactivityTimeout
        } else if lastSessionEndReason == .maxDuration {
            startPrecondition = .maxDuration
        } else {
            dependencies.telemetry.error("Failed to determine session precondition for REFRESHED session with end reason: \(lastSessionEndReason?.rawValue ?? "unknown"))")
        }

        let refreshingInForeground = context.applicationStateHistory.currentState == .active
        let lastActiveViewPath = expiredSession.viewScopes.last(where: { $0.isActiveView })?.viewPath
        let transferActiveView = command.shouldRestartLastViewAfterSessionExpiration
            && refreshingInForeground
            && lastActiveViewPath != RUMOffViewEventsHandlingRule.Constants.backgroundViewURL

        let refreshedSession = RUMSessionScope(
            from: expiredSession,
            startTime: command.time,
            startPrecondition: startPrecondition,
            context: context,
            transferActiveView: transferActiveView,
            applicationState: applicationState,
            isForced: isForcedSession
        )
        sessionScopeDidUpdate(refreshedSession)
        lastActiveView = nil
        lastSessionEndReason = nil
        _ = refreshedSession.process(command: command, context: context, writer: writer)
        return refreshedSession
    }

    private func startNewSession(on command: RUMCommand, context: DatadogContext, writer: Writer) {
        var startPrecondition: RUMSessionPrecondition? = nil

        if lastSessionEndReason == .stopAPI {
            startPrecondition = .explicitStop
        } else if lastSessionEndReason == .timeOut {
            startPrecondition = .inactivityTimeout
        } else if lastSessionEndReason == .maxDuration {
            startPrecondition = .maxDuration
        } else {
            dependencies.telemetry.error("Failed to determine session precondition for NEW session with end reason: \(lastSessionEndReason?.rawValue ?? "unknown"))")
        }

        if didCreateInitialSessionCount > 0 { // Sanity check
            // This is a non-initial session (initial sessions are created via `RUMSDKInitCommand`)
            dependencies.telemetry.debug("Starting new session triggered by \(type(of: command)). Previous session was stopped for the following reason: \(startPrecondition?.rawValue ?? "unknown")")
        }

        let startingInForeground = context.applicationStateHistory.currentState == .active
        var resumeViewScope = false

        if lastSessionEndReason == .stopAPI {
            resumeViewScope = command.shouldRestartLastViewAfterSessionStop && startingInForeground
        } else if lastSessionEndReason == .timeOut || lastSessionEndReason == .maxDuration {
            resumeViewScope = command.shouldRestartLastViewAfterSessionExpiration && startingInForeground
        }

        let newSession = RUMSessionScope(
            isInitialSession: false,
            parent: self,
            startTime: command.time,
            startPrecondition: startPrecondition,
            context: context,
            dependencies: dependencies,
            applicationState: applicationState,
            isForced: isForcedSession,
            resumingViewScope: resumeViewScope ? lastActiveView : nil
        )
        lastActiveView = nil
        lastSessionEndReason = nil
        sessionScopes.append(newSession)
        sessionScopeDidUpdate(newSession)
    }

    private func sessionScopeDidUpdate(_ sessionScope: RUMSessionScope) {
        let sessionID = sessionScope.sessionUUID.rawValue.uuidString
        let isDiscarded = !sessionScope.isSampled
        dependencies.onSessionStart?(sessionID, isDiscarded)
    }

    /// Forces the `ApplicationLaunchView` to be started.
    /// Added as part of https://github.com/DataDog/dd-sdk-ios/pull/1290 to separate creation of first view
    /// from creation of initial session due to receiving `RUMSDKInitCommand`. Starting from RUM-1649 the "application launch" view
    /// is started on SDK init only when the app is launched by user with no prewarming or when app was prewarmed but SDK was initialized
    /// after it became active.
    private func startApplicationLaunchView(on command: RUMCommand, context: DatadogContext, writer: Writer) {
        applicationActive = true

        let isUserLaunch = context.launchInfo.launchReason == .userLaunch
        let isPrewarmed = context.launchInfo.launchReason == .prewarming
        let isBackgroundLaunch = context.launchInfo.launchReason == .backgroundLaunch
        let isStartedInForeground = command is RUMSDKInitCommand && context.applicationStateHistory.currentState != .background
        guard isUserLaunch || (isPrewarmed && isStartedInForeground) || (isBackgroundLaunch && isStartedInForeground) else {
            return
        }

        // Immediately start the ApplicationLaunchView for the new session
        _ = process(
            command: RUMApplicationStartCommand(
                time: command.time,
                globalAttributes: command.globalAttributes,
                attributes: command.attributes
            ),
            context: context,
            writer: writer
        )
    }
}
