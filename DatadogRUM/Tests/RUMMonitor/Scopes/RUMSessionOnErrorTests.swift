/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import XCTest
import DatadogInternal
@testable import DatadogRUM
@testable import TestUtilities

/// Sessions kept only in case they report an error (`sessionOnError`), from the draw to the
/// release or the discard of what they withheld.
class RUMSessionOnErrorTests: XCTestCase {
    private let start = Date()
    private let writer = FileWriterMock()
    private let featureScope = FeatureScopeMock()
    private let fatalErrorContext = FatalErrorContextNotifierMock()
    /// Releases scheduled through the jitter, in order. Firing one runs the release.
    private var scheduledReleases: [(delay: TimeInterval, fire: () -> Void)] = []
    private var sessionStarts: [(id: String, isDiscarded: Bool)] = []

    private func makeScope(
        sessionSampleRate: SampleRate = 0,
        sessionOnError: Bool = true,
        remoteRates: @escaping () -> RemoteSamplingRates? = { nil },
        beforeSampling: BeforeSamplingCallback? = nil,
        errorEventMapper: RUM.ErrorEventMapper? = nil
    ) -> RUMApplicationScope {
        let scope = RUMApplicationScope(
            dependencies: .mockWith(
                featureScope: featureScope,
                sessionSampler: Sampler(samplingRate: sessionSampleRate),
                eventBuilder: RUMEventBuilder(eventsMapper: .mockWith(errorEventMapper: errorEventMapper)),
                onSessionStart: { [unowned self] id, isDiscarded in self.sessionStarts.append((id, isDiscarded)) },
                fatalErrorContext: fatalErrorContext,
                remoteSamplingRates: remoteRates,
                beforeSampling: beforeSampling,
                sessionOnError: sessionOnError,
                scheduleWithheldEventsRelease: { [unowned self] delay, fire in self.scheduledReleases.append((delay, fire)) }
            )
        )
        process(RUMSDKInitCommand(time: start, globalAttributes: [:]), on: scope)
        return scope
    }

    /// What Session Replay publishes, as RUM reads it from the core context.
    private var replayContext: [AdditionalContext] = []
    private var trackingConsent: TrackingConsent = .granted

    private func process(_ command: RUMCommand, on scope: RUMApplicationScope) {
        var context: DatadogContext = .mockWith(sdkInitDate: start, trackingConsent: trackingConsent)
        replayContext.forEach { context.set(additionalContext: $0) }
        _ = scope.process(command: command, context: context, writer: writer)
    }

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    private func startView(_ name: String, at seconds: TimeInterval, on scope: RUMApplicationScope) {
        process(RUMStartViewCommand.mockWith(time: at(seconds), identity: .mockViewIdentifier(), name: name, path: name), on: scope)
    }

    private func addError(at seconds: TimeInterval, on scope: RUMApplicationScope, isCrash: Bool? = nil, message: String = "boom") {
        process(
            RUMAddCurrentViewErrorCommand(
                time: at(seconds),
                message: message,
                type: "Error",
                stack: nil,
                source: .source,
                isCrash: isCrash,
                threads: nil,
                binaryImages: nil,
                isStackTraceTruncated: nil,
                globalAttributes: [:],
                attributes: [:],
                completionHandler: {}
            ),
            on: scope
        )
    }

    private func addAction(at seconds: TimeInterval, on scope: RUMApplicationScope) {
        process(RUMAddUserActionCommand.mockWith(time: at(seconds), actionType: .custom), on: scope)
    }

    /// Everything that reached a real writer: the one handed to the scope, and the one the
    /// jittered release writes through.
    private var written: [Encodable] { writer.events + featureScope.eventsWritten }

    private func written<T: Encodable>(_ type: T.Type) -> [T] { written.compactMap { $0 as? T } }

    private func fireScheduledReleases() {
        let releases = scheduledReleases
        scheduledReleases = []
        releases.forEach { $0.fire() }
    }

    // MARK: - Draw

    func testARateThatLeavesTheSessionOut_withTheSwitchOn_keepsItOnErrorWithAnID() throws {
        let scope = makeScope(sessionSampleRate: 0, sessionOnError: true)
        let session = try XCTUnwrap(scope.activeSession)

        XCTAssertFalse(session.isSampled)
        XCTAssertTrue(session.isSampledOnError)
        XCTAssertNotEqual(session.sessionUUID, .nullUUID, "its events are assembled, so it needs an id")
        XCTAssertTrue(session.context.eventsWithheld)
        XCTAssertEqual(fatalErrorContext.sessionState?.sampledForError, true)
    }

    func testWithTheSwitchOff_aSessionLeftOutIsNotTracked() throws {
        let scope = makeScope(sessionSampleRate: 0, sessionOnError: false)
        let session = try XCTUnwrap(scope.activeSession)

        XCTAssertFalse(session.isTracked)
        XCTAssertEqual(session.sessionUUID, .nullUUID)
    }

    func testASessionTheRateCollects_isNeverKeptOnError() throws {
        let scope = makeScope(sessionSampleRate: 100, sessionOnError: true)
        let session = try XCTUnwrap(scope.activeSession)

        XCTAssertTrue(session.isSampled)
        XCTAssertFalse(session.isSampledOnError, "a session is never counted by both")
        XCTAssertFalse(session.context.eventsWithheld)
        XCTAssertNil(fatalErrorContext.sessionState?.sampledForError)
    }

    func testTheConsoleSwitchTakesPrecedenceOverTheInitValue() throws {
        let turnedOn = makeScope(sessionOnError: false, remoteRates: { RemoteSamplingRates(sessionSampleRate: nil, sessionOnError: true) })
        XCTAssertEqual(turnedOn.activeSession?.isSampledOnError, true)

        let turnedOff = makeScope(sessionOnError: true, remoteRates: { RemoteSamplingRates(sessionSampleRate: nil, sessionOnError: false) })
        XCTAssertEqual(turnedOff.activeSession?.isSampledOnError, false)

        let unset = makeScope(sessionOnError: true, remoteRates: { RemoteSamplingRates(sessionSampleRate: 0) })
        XCTAssertEqual(unset.activeSession?.isSampledOnError, true, "an absent switch keeps the init value")
    }

    func testBeforeSamplingReturningZero_turnsTheSwitchOff() {
        // "0 never collects" is the hook's contract; on-error must not quietly turn it into
        // "collects on error".
        let zero = makeScope(sessionSampleRate: 100, beforeSampling: { _ in 0 })
        XCTAssertEqual(zero.activeSession?.isTracked, false)

        let untouched = makeScope(sessionSampleRate: 0, beforeSampling: { _ in nil })
        XCTAssertEqual(untouched.activeSession?.isSampledOnError, true, "a hook with no opinion keeps the switch")
    }

    func testASessionKeptOnErrorIsReportedAsDiscardedWhenItStarts() throws {
        let scope = makeScope()
        let session = try XCTUnwrap(scope.activeSession)

        XCTAssertEqual(sessionStarts.last?.id, session.sessionUUID.rawValue.uuidString)
        XCTAssertEqual(sessionStarts.last?.isDiscarded, true, "until it errors, the backend has no such session")
    }

    // MARK: - Withholding

    func testWithoutAnError_nothingIsWritten_andTheSessionIsThrownAwayWhenItEnds() throws {
        let scope = makeScope()
        startView("Home", at: 1, on: scope)
        addAction(at: 2, on: scope)
        let view = try XCTUnwrap(fatalErrorContext.view)
        XCTAssertEqual(view.session.sampledForError, true, "the crash context still gets the view, locally")

        process(RUMStopSessionCommand(time: at(3)), on: scope)
        fireScheduledReleases()

        XCTAssertTrue(written.isEmpty)
        XCTAssertTrue(scheduledReleases.isEmpty)
    }

    func testAnError_releasesTheMinuteBeforeIt_behindTheSessionsJitter() throws {
        let scope = makeScope()
        let session = try XCTUnwrap(scope.activeSession)
        startView("Home", at: 1, on: scope)
        addAction(at: 2, on: scope)

        addError(at: 3, on: scope)

        XCTAssertTrue(written.isEmpty, "the release waits for its jitter")
        XCTAssertTrue(session.context.eventsWithheld, "nothing else of the session may go out ahead of its views")
        XCTAssertTrue(session.context.sessionHasReportedError)
        let release = try XCTUnwrap(scheduledReleases.first)
        XCTAssertEqual(release.delay, RUMWithheldEventBuffer.releaseDelay(sessionID: session.sessionUUID.toRUMDataFormat))

        addAction(at: 4, on: scope) // arrives while the release is pending
        fireScheduledReleases()

        let views = written(RUMViewEvent.self)
        XCTAssertFalse(views.isEmpty)
        XCTAssertTrue(written.first is RUMViewEvent, "views lead the release")
        XCTAssertEqual(written(RUMErrorEvent.self).count, 1)
        XCTAssertEqual(written(RUMActionEvent.self).count, 2, "the event that arrived while waiting goes with the rest")
        XCTAssertTrue(views.allSatisfy { $0.session.sampledForError == true })
        XCTAssertTrue(views.allSatisfy { $0.dd.configuration?.sessionSampleRate == 0 })
        XCTAssertTrue(written(RUMErrorEvent.self).allSatisfy { $0.dd.configuration?.sessionSampleRate == 0 })
        XCTAssertTrue(written(RUMActionEvent.self).allSatisfy { $0.dd.configuration?.sessionSampleRate == 0 })

        // From then on, the session's events go straight through.
        let countBefore = written.count
        addAction(at: 5, on: scope)
        XCTAssertEqual(written.count, countBefore + 2) // the action and its view update
        XCTAssertTrue(scheduledReleases.isEmpty)
    }

    func testAJitteredRelease_tellsTheOtherFeaturesTheEventsAreOut() throws {
        // Released outside of any command, so the context the replay and the web views wait on
        // has to be published by the release itself.
        let scope = makeScope()
        startView("Home", at: 1, on: scope)
        addError(at: 2, on: scope)
        scope.publishCoreContext()
        XCTAssertEqual(featureScope.contextMock.additionalContext(ofType: RUMCoreContext.self)?.eventsWithheld, true)

        fireScheduledReleases()

        let published = try XCTUnwrap(featureScope.contextMock.additionalContext(ofType: RUMCoreContext.self))
        XCTAssertFalse(published.eventsWithheld)
        XCTAssertTrue(published.hasReportedError)
        XCTAssertFalse(written(RUMViewEvent.self).isEmpty, "the events were written before the context said so")
    }

    func testTheReleaseIsReportedToTelemetry() {
        let scope = makeScope()
        startView("Home", at: 1, on: scope)
        addError(at: 2, on: scope)
        fireScheduledReleases()

        let debug = featureScope.telemetryMock.messages.compactMap { message -> [String: Encodable]? in
            guard case let .debug(_, text, attributes) = message, text == "Error session event buffer released" else {
                return nil
            }
            return attributes
        }
        XCTAssertEqual(debug.count, 1)
        XCTAssertNotNil(debug.first?["buffer.views_count"])
        XCTAssertNotNil(debug.first?["buffer.events_count"])
        XCTAssertNotNil(debug.first?["buffer.dropped_count"])
        XCTAssertNotNil(debug.first?["buffer.bytes"])
    }

    func testAnErrorTheMapperDrops_releasesNothing() {
        let scope = makeScope(errorEventMapper: { _ in nil })
        startView("Home", at: 1, on: scope)
        addError(at: 2, on: scope)

        XCTAssertTrue(scheduledReleases.isEmpty)
        XCTAssertEqual(scope.activeSession?.context.eventsWithheld, true)

        process(RUMStopSessionCommand(time: at(3)), on: scope)
        XCTAssertTrue(written.isEmpty, "a session must not be billed for an error nobody can find")
    }

    func testControl_anErrorTheMapperKeeps_releases() {
        let scope = makeScope(errorEventMapper: { $0 })
        startView("Home", at: 1, on: scope)
        addError(at: 2, on: scope)
        fireScheduledReleases()

        XCTAssertEqual(written(RUMErrorEvent.self).count, 1)
    }

    func testWhenTheSessionEndsAfterItsError_theReleaseDoesNotWaitForTheJitter() {
        let scope = makeScope()
        startView("Home", at: 1, on: scope)
        addError(at: 2, on: scope)

        process(RUMStopSessionCommand(time: at(3)), on: scope)

        XCTAssertEqual(written(RUMErrorEvent.self).count, 1)
        let countAfterEnd = written.count
        fireScheduledReleases()
        XCTAssertEqual(written.count, countAfterEnd, "the late timer finds nothing left to write")
    }

    func testWhenTheSessionTimesOutWithoutAnError_itsBufferIsThrownAway() {
        let scope = makeScope()
        startView("Home", at: 1, on: scope)
        addAction(at: 2, on: scope)

        addAction(at: 2 + RUMSessionScope.Constants.sessionTimeoutDuration + 1, on: scope)

        XCTAssertTrue(written.isEmpty, "neither the old session nor the new one has reported an error")
        XCTAssertEqual(scope.activeSession?.isSampledOnError, true, "the next session is drawn the same way")
    }

    func testGoingToTheBackground_sendsAScheduledReleaseNow() {
        let scope = makeScope()
        startView("Home", at: 1, on: scope)
        addError(at: 2, on: scope)

        process(RUMHandleAppLifecycleEventCommand(time: at(3), event: .didEnterBackground), on: scope)

        XCTAssertEqual(written(RUMErrorEvent.self).count, 1)
    }

    func testGoingToTheBackgroundWithoutAnError_keepsTheBuffer() {
        let scope = makeScope()
        startView("Home", at: 1, on: scope)
        addAction(at: 2, on: scope)

        process(RUMHandleAppLifecycleEventCommand(time: at(3), event: .didEnterBackground), on: scope)
        XCTAssertTrue(written.isEmpty)

        process(RUMHandleAppLifecycleEventCommand(time: at(4), event: .willEnterForeground), on: scope)
        addError(at: 5, on: scope)
        fireScheduledReleases()
        XCTAssertEqual(written(RUMActionEvent.self).count, 1, "what came before the background trip is still there")
    }

    func testForcingTheSession_releasesAtOnce_andKeepsTheSession() throws {
        let scope = makeScope()
        let session = try XCTUnwrap(scope.activeSession)
        startView("Home", at: 1, on: scope)
        addAction(at: 2, on: scope)

        process(RUMSetForcedSessionCommand(time: at(3)), on: scope)

        XCTAssertTrue(scheduledReleases.isEmpty, "no jitter for a session the application asked for")
        XCTAssertEqual(written(RUMActionEvent.self).count, 1)
        XCTAssertEqual(scope.activeSession?.sessionUUID, session.sessionUUID)
        XCTAssertEqual(scope.activeSession?.context.sessionForced, true)
        XCTAssertEqual(scope.activeSession?.context.eventsWithheld, false)
    }

    func testForcingACollectedSession_marksItForced_withoutEndingIt() throws {
        // Its replay may be kept on error, and forcing is what releases that.
        let scope = makeScope(sessionSampleRate: 100, sessionOnError: false)
        let session = try XCTUnwrap(scope.activeSession)
        startView("Home", at: 1, on: scope)
        XCTAssertEqual(session.context.sessionForced, false)

        process(RUMSetForcedSessionCommand(time: at(2)), on: scope)

        XCTAssertTrue(scope.activeSession === session, "a collected session keeps running")
        XCTAssertEqual(session.context.sessionForced, true)
        XCTAssertTrue(scheduledReleases.isEmpty)
    }

    func testACrashReportedInProcess_releasesAtOnce() {
        let scope = makeScope()
        startView("Home", at: 1, on: scope)

        addError(at: 2, on: scope, isCrash: true)

        XCTAssertEqual(written(RUMErrorEvent.self).count, 1, "the process is about to go away and the buffer with it")
    }

    func testACrashLargerThanTheWholeBudget_stillReleasesTheHistoryAtOnce() {
        // A crash with its threads and binary images easily outgrows the budget. It goes out on
        // its own, but the process is still about to go away: the history goes with it, now.
        let scope = makeScope()
        startView("Home", at: 1, on: scope)
        addAction(at: 2, on: scope)

        addError(at: 3, on: scope, isCrash: true, message: String(repeating: "x", count: RUMWithheldEventBuffer.Constants.bytesLimit + 1))

        XCTAssertEqual(written(RUMErrorEvent.self).count, 1)
        XCTAssertEqual(written(RUMActionEvent.self).count, 1, "the history did not wait for a jitter the process will not live to see")
        XCTAssertEqual(scope.activeSession?.context.eventsWithheld, false)
    }

    func testForcingTheSession_releasesTheMinuteBeforeTheForcing_notBeforeTheLastCommand() {
        let scope = makeScope()
        startView("Home", at: 1, on: scope)
        addAction(at: 2, on: scope)

        process(RUMSetForcedSessionCommand(time: at(2 + RUMWithheldEventBuffer.Constants.duration + 30)), on: scope)

        XCTAssertFalse(written(RUMViewEvent.self).isEmpty, "the view in progress always goes")
        XCTAssertTrue(written(RUMActionEvent.self).isEmpty, "older than the minute before the forcing")
    }

    func testInACollectedSession_aFailedRequestReleasingAWithheldReplay_claimsIt() throws {
        let scope = makeScope(sessionSampleRate: 100)
        startView("Home", at: 1, on: scope)
        try replayKeptOnError(by: scope, withheld: true, records: 5)
        process(RUMStartResourceCommand.mockWith(resourceKey: "/api", time: at(1.5)), on: scope)

        process(RUMStopResourceWithErrorCommand.mockWithErrorMessage(resourceKey: "/api", time: at(2), httpStatusCode: 500), on: scope)

        let error = try XCTUnwrap(written(RUMErrorEvent.self).first)
        XCTAssertNotNil(error.error.resource, "the failed request's error")
        XCTAssertEqual(error.session.hasReplay, true, "the error that releases the replay is the one the console opens it from")
        XCTAssertTrue(scope.activeSession?.context.sessionHasReportedError == true)
    }

    func testControl_aSessionTheRateCollects_carriesNoMarkerAndItsRealRate() {
        let scope = makeScope(sessionSampleRate: 100)
        startView("Home", at: 1, on: scope)
        addError(at: 2, on: scope)

        let views = written(RUMViewEvent.self)
        XCTAssertFalse(views.isEmpty, "a collected session writes straight away")
        XCTAssertTrue(views.allSatisfy { $0.session.sampledForError == nil })
        XCTAssertTrue(views.allSatisfy { $0.dd.configuration?.sessionSampleRate == 100 })
        XCTAssertTrue(scheduledReleases.isEmpty)
    }

    // MARK: - Consent

    func testWhatWasAssembledWithoutConsent_isNeverReleased() {
        // An ordinary session drops what it assembles while consent is not granted. A session kept
        // on error must not hold it instead and upload it once consent is granted.
        let scope = makeScope()
        trackingConsent = .notGranted
        startView("Home", at: 1, on: scope)
        addAction(at: 2, on: scope)

        trackingConsent = .granted
        addAction(at: 3, on: scope)
        addError(at: 4, on: scope)
        fireScheduledReleases()

        XCTAssertEqual(written(RUMActionEvent.self).count, 1, "only what was assembled once consent was granted")
        XCTAssertEqual(written(RUMErrorEvent.self).count, 1)
    }

    func testAnErrorAssembledWithoutConsent_doesNotReleaseTheSession() {
        let scope = makeScope()
        startView("Home", at: 1, on: scope)
        trackingConsent = .notGranted
        addError(at: 2, on: scope)
        trackingConsent = .granted

        XCTAssertTrue(scheduledReleases.isEmpty, "an error that was never collected cannot be the reason the session is")
        process(RUMStopSessionCommand(time: at(3)), on: scope)
        XCTAssertTrue(written.isEmpty)
    }

    func testWhenConsentIsWithdrawn_whatWasHeldIsThrownAway_andTheSessionGoesOnWithholding() {
        let scope = makeScope()
        startView("Home", at: 1, on: scope)
        addAction(at: 2, on: scope)

        scope.discardWithheldEvents() // what the consent receiver does on a withdrawal

        addAction(at: 3, on: scope)
        addError(at: 4, on: scope)
        fireScheduledReleases()

        XCTAssertEqual(written(RUMActionEvent.self).count, 1, "only what was held after consent returned")
        XCTAssertEqual(written(RUMErrorEvent.self).count, 1)
    }

    func testControl_whatWasAssembledWithPendingConsent_isReleased() {
        // Pending consent is what the pending storage is for: the release writes through the
        // writer of the moment, which keeps or purges it with the consent decision.
        let scope = makeScope()
        trackingConsent = .pending
        startView("Home", at: 1, on: scope)
        addAction(at: 2, on: scope)
        addError(at: 3, on: scope)
        fireScheduledReleases()

        XCTAssertEqual(written(RUMActionEvent.self).count, 1)
    }

    // MARK: - Replay kept on error

    private func replayKeptOnError(by scope: RUMApplicationScope, withheld: Bool, records: Int64) throws {
        let session = try XCTUnwrap(scope.activeSession)
        let viewID = try XCTUnwrap(session.viewScopes.last?.viewUUID.toRUMDataFormat)
        replayContext = [
            SessionReplayCoreContext.ErrorReplay(sessionID: session.sessionUUID.toRUMDataFormat, withheld: withheld),
            SessionReplayCoreContext.RecordsCount(value: [viewID: records]),
            SessionReplayCoreContext.HasReplay(value: !withheld)
        ]
        replayContext.forEach { featureScope.contextMock.set(additionalContext: $0) } // what the jittered release reads
    }

    func testAReplayWithheldWithTheEvents_isReportedAsSampled_andReleasedEventsClaimIt() throws {
        let scope = makeScope()
        startView("Home", at: 1, on: scope)
        try replayKeptOnError(by: scope, withheld: true, records: 5)
        addAction(at: 2, on: scope)

        addError(at: 3, on: scope)
        fireScheduledReleases()

        // The view the replay recorded; the launch view before it was assembled before any replay.
        let views = written(RUMViewEvent.self).filter { $0.view.name == "Home" }
        XCTAssertFalse(views.isEmpty)
        XCTAssertTrue(views.allSatisfy { $0.session.sampledForErrorReplay == true })
        XCTAssertTrue(views.allSatisfy { $0.session.sampledForReplay == true }, "the replay goes out with these events")
        XCTAssertTrue(views.allSatisfy { $0.session.hasReplay == true }, "their view kept records, released alongside")
        XCTAssertEqual(written(RUMErrorEvent.self).first?.session.hasReplay, true)
        XCTAssertTrue(written(RUMActionEvent.self).allSatisfy { $0.session.hasReplay == true })
    }

    func testControl_anOrdinarySessionWithReplay_reportsExactlyWhatItAlwaysDid() throws {
        let scope = makeScope(sessionSampleRate: 100, sessionOnError: false)
        replayContext = [SessionReplayCoreContext.HasReplay(value: true)]
        startView("Home", at: 1, on: scope)
        addError(at: 2, on: scope)

        let views = written(RUMViewEvent.self).filter { $0.view.name == "Home" }
        XCTAssertFalse(views.isEmpty)
        XCTAssertTrue(views.allSatisfy { $0.session.hasReplay == true })
        XCTAssertTrue(views.allSatisfy { $0.session.sampledForReplay == nil })
        XCTAssertTrue(views.allSatisfy { $0.session.sampledForErrorReplay == nil && $0.session.sampledForError == nil })
    }

    func testControl_aViewWhoseWithheldReplayWasThrownAway_claimsNoReplay() throws {
        let scope = makeScope()
        startView("Home", at: 1, on: scope)
        try replayKeptOnError(by: scope, withheld: true, records: 0)
        addAction(at: 2, on: scope)

        addError(at: 3, on: scope)
        fireScheduledReleases()

        XCTAssertFalse(written(RUMViewEvent.self).isEmpty)
        XCTAssertTrue(written(RUMViewEvent.self).allSatisfy { $0.session.hasReplay != true })
        XCTAssertNotEqual(written(RUMErrorEvent.self).first?.session.hasReplay, true)
    }

    func testInACollectedSession_theErrorReleasingAWithheldReplay_claimsIt() throws {
        let scope = makeScope(sessionSampleRate: 100)
        startView("Home", at: 1, on: scope)
        try replayKeptOnError(by: scope, withheld: true, records: 5)
        addAction(at: 1.5, on: scope)
        let viewBeforeTheError = try XCTUnwrap(written(RUMViewEvent.self).last)
        XCTAssertNil(viewBeforeTheError.session.sampledForReplay, "withheld while the events are not: it may never be uploaded")
        XCTAssertNil(viewBeforeTheError.dd.replayStats?.recordsCount, "withheld records may yet be thrown away")

        addError(at: 2, on: scope)

        XCTAssertEqual(written(RUMErrorEvent.self).first?.session.hasReplay, true)
        let lastView = try XCTUnwrap(written(RUMViewEvent.self).last)
        XCTAssertEqual(lastView.session.sampledForErrorReplay, true)
        XCTAssertEqual(lastView.session.sampledForReplay, true, "the error releases it")
        XCTAssertNil(lastView.session.sampledForError)
    }

    // MARK: - Remote configuration

    private func announceRatesChanged(at seconds: TimeInterval, to scope: RUMApplicationScope, activation: RemoteSamplingActivation = .nextSession) {
        process(RUMRemoteSamplingChangedCommand(activation: activation, time: at(seconds)), on: scope)
    }

    func testRateZeroWithTheSwitchOn_doesNotEndASessionKeptOnError() throws {
        // "Only the sessions that error" is exactly this configuration. Ending the session on every
        // first fetch would throw away the launch, which is where the errors are.
        var rates: RemoteSamplingRates? = nil
        let scope = makeScope(sessionOnError: true, remoteRates: { rates })
        let session = try XCTUnwrap(scope.activeSession)

        rates = RemoteSamplingRates(sessionSampleRate: 0, version: 1, sessionOnError: true)
        announceRatesChanged(at: 1, to: scope)
        announceRatesChanged(at: 2, to: scope, activation: .immediate)

        XCTAssertEqual(scope.activeSession?.sessionUUID, session.sessionUUID)
    }

    func testControl_rateZeroWithTheSwitchOff_endsASessionKeptOnError_andThrowsItsBufferAway() throws {
        var rates: RemoteSamplingRates? = nil
        let scope = makeScope(sessionOnError: true, remoteRates: { rates })
        startView("Home", at: 1, on: scope)

        rates = RemoteSamplingRates(sessionSampleRate: 0, version: 1, sessionOnError: false)
        announceRatesChanged(at: 2, to: scope)

        XCTAssertNil(scope.activeSession)
        XCTAssertTrue(written.isEmpty)
    }

    func testASessionDrawnOutAtZero_isRedrawnWhenTheSwitchTurnsOn() throws {
        var rates: RemoteSamplingRates? = RemoteSamplingRates(sessionSampleRate: 0, version: 1, sessionOnError: false)
        let scope = makeScope(sessionOnError: false, remoteRates: { rates })
        XCTAssertEqual(scope.activeSession?.isTracked, false)

        rates = RemoteSamplingRates(sessionSampleRate: 0, version: 2, sessionOnError: true)
        announceRatesChanged(at: 1, to: scope)
        XCTAssertNil(scope.activeSession, "nothing would ever be seen until the session rotated")

        addAction(at: 2, on: scope)
        XCTAssertEqual(scope.activeSession?.isSampledOnError, true)
    }

    func testControl_aSessionDrawnOutAtZero_isLeftAloneWhileTheSwitchStaysOff() throws {
        var rates: RemoteSamplingRates? = RemoteSamplingRates(sessionSampleRate: 0, version: 1, sessionOnError: false)
        let scope = makeScope(sessionOnError: false, remoteRates: { rates })
        let session = try XCTUnwrap(scope.activeSession)

        rates = RemoteSamplingRates(sessionSampleRate: 0, version: 2, sessionOnError: false)
        announceRatesChanged(at: 1, to: scope)

        XCTAssertEqual(scope.activeSession?.sessionUUID, session.sessionUUID)
    }

    func testARisingRate_leavesASessionKeptOnErrorAlone() throws {
        var rates: RemoteSamplingRates? = RemoteSamplingRates(sessionSampleRate: 0, version: 1, sessionOnError: true)
        let scope = makeScope(remoteRates: { rates })
        let session = try XCTUnwrap(scope.activeSession)

        rates = RemoteSamplingRates(sessionSampleRate: 50, version: 2, sessionOnError: true)
        announceRatesChanged(at: 1, to: scope)

        XCTAssertEqual(scope.activeSession?.sessionUUID, session.sessionUUID, "the draw is locked for the session")
    }

    func testASwitchTurnedOnMidSession_doesNotChangeASessionDrawnAtANonZeroRate() throws {
        var rates: RemoteSamplingRates? = RemoteSamplingRates(sessionSampleRate: 20, version: 1, sessionOnError: false)
        let scope = makeScope(sessionSampleRate: 20, sessionOnError: false, remoteRates: { rates })
        let session = try XCTUnwrap(scope.activeSession)

        rates = RemoteSamplingRates(sessionSampleRate: 20, version: 2, sessionOnError: true)
        announceRatesChanged(at: 1, to: scope)

        XCTAssertEqual(scope.activeSession?.sessionUUID, session.sessionUUID)
        XCTAssertEqual(scope.activeSession?.isSampledOnError, false)
    }
}
