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

    private func process(_ command: RUMCommand, on scope: RUMApplicationScope) {
        _ = scope.process(command: command, context: .mockWith(sdkInitDate: start), writer: writer)
    }

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    private func startView(_ name: String, at seconds: TimeInterval, on scope: RUMApplicationScope) {
        process(RUMStartViewCommand.mockWith(time: at(seconds), identity: .mockViewIdentifier(), name: name, path: name), on: scope)
    }

    private func addError(at seconds: TimeInterval, on scope: RUMApplicationScope, isCrash: Bool? = nil) {
        process(
            RUMAddCurrentViewErrorCommand(
                time: at(seconds),
                message: "boom",
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
        XCTAssertFalse(session.context.eventsWithheld, "everything else learns of the error at once")
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

    func testACrashReportedInProcess_releasesAtOnce() {
        let scope = makeScope()
        startView("Home", at: 1, on: scope)

        addError(at: 2, on: scope, isCrash: true)

        XCTAssertEqual(written(RUMErrorEvent.self).count, 1, "the process is about to go away and the buffer with it")
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

        rates = RemoteSamplingRates(sessionSampleRate: 0, sessionOnError: true, version: 1)
        announceRatesChanged(at: 1, to: scope)
        announceRatesChanged(at: 2, to: scope, activation: .immediate)

        XCTAssertEqual(scope.activeSession?.sessionUUID, session.sessionUUID)
    }

    func testControl_rateZeroWithTheSwitchOff_endsASessionKeptOnError_andThrowsItsBufferAway() throws {
        var rates: RemoteSamplingRates? = nil
        let scope = makeScope(sessionOnError: true, remoteRates: { rates })
        startView("Home", at: 1, on: scope)

        rates = RemoteSamplingRates(sessionSampleRate: 0, sessionOnError: false, version: 1)
        announceRatesChanged(at: 2, to: scope)

        XCTAssertNil(scope.activeSession)
        XCTAssertTrue(written.isEmpty)
    }

    func testASessionDrawnOutAtZero_isRedrawnWhenTheSwitchTurnsOn() throws {
        var rates: RemoteSamplingRates? = RemoteSamplingRates(sessionSampleRate: 0, sessionOnError: false, version: 1)
        let scope = makeScope(sessionOnError: false, remoteRates: { rates })
        XCTAssertEqual(scope.activeSession?.isTracked, false)

        rates = RemoteSamplingRates(sessionSampleRate: 0, sessionOnError: true, version: 2)
        announceRatesChanged(at: 1, to: scope)
        XCTAssertNil(scope.activeSession, "nothing would ever be seen until the session rotated")

        addAction(at: 2, on: scope)
        XCTAssertEqual(scope.activeSession?.isSampledOnError, true)
    }

    func testControl_aSessionDrawnOutAtZero_isLeftAloneWhileTheSwitchStaysOff() throws {
        var rates: RemoteSamplingRates? = RemoteSamplingRates(sessionSampleRate: 0, sessionOnError: false, version: 1)
        let scope = makeScope(sessionOnError: false, remoteRates: { rates })
        let session = try XCTUnwrap(scope.activeSession)

        rates = RemoteSamplingRates(sessionSampleRate: 0, sessionOnError: false, version: 2)
        announceRatesChanged(at: 1, to: scope)

        XCTAssertEqual(scope.activeSession?.sessionUUID, session.sessionUUID)
    }

    func testARisingRate_leavesASessionKeptOnErrorAlone() throws {
        var rates: RemoteSamplingRates? = RemoteSamplingRates(sessionSampleRate: 0, sessionOnError: true, version: 1)
        let scope = makeScope(remoteRates: { rates })
        let session = try XCTUnwrap(scope.activeSession)

        rates = RemoteSamplingRates(sessionSampleRate: 50, sessionOnError: true, version: 2)
        announceRatesChanged(at: 1, to: scope)

        XCTAssertEqual(scope.activeSession?.sessionUUID, session.sessionUUID, "the draw is locked for the session")
    }

    func testASwitchTurnedOnMidSession_doesNotChangeASessionDrawnAtANonZeroRate() throws {
        var rates: RemoteSamplingRates? = RemoteSamplingRates(sessionSampleRate: 20, sessionOnError: false, version: 1)
        let scope = makeScope(sessionSampleRate: 20, sessionOnError: false, remoteRates: { rates })
        let session = try XCTUnwrap(scope.activeSession)

        rates = RemoteSamplingRates(sessionSampleRate: 20, sessionOnError: true, version: 2)
        announceRatesChanged(at: 1, to: scope)

        XCTAssertEqual(scope.activeSession?.sessionUUID, session.sessionUUID)
        XCTAssertEqual(scope.activeSession?.isSampledOnError, false)
    }
}
