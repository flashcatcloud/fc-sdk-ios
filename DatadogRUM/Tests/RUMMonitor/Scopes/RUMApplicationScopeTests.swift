/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import XCTest
import DatadogInternal
@testable import DatadogRUM
@testable import TestUtilities

class RUMApplicationScopeTests: XCTestCase {
    let writer = FileWriterMock()

    /// Creates `RUMApplicationScope` instance and configures it with the effects applied when RUM gets enabled.
    /// TODO: RUM-1649 Move this configuration to `RUMApplicationScope.init()`, so we can remove this setup in tests.
    private func createRUMApplicationScope(
        dependencies: RUMScopeDependencies,
        sdkContext: DatadogContext = .mockWith(sdkInitDate: Date())
    ) -> RUMApplicationScope {
        let scope = RUMApplicationScope(dependencies: dependencies)
        // Always receive `RUMSDKInitCommand` as the very first command (see: `Monitor.notifySDKInit()`)
        let initCommand = RUMSDKInitCommand(time: sdkContext.sdkInitDate, globalAttributes: [:])
        _ = scope.process(command: initCommand, context: sdkContext, writer: writer)
        return scope
    }

    func testRootContext() {
        let scope = createRUMApplicationScope(
            dependencies: .mockWith(rumApplicationID: "abc-123")
        )

        XCTAssertEqual(scope.context.rumApplicationID, "abc-123")
        XCTAssertEqual(scope.context.sessionID, .nullUUID)
        XCTAssertNil(scope.context.activeViewID)
        XCTAssertNil(scope.context.activeViewPath)
        XCTAssertNil(scope.context.activeUserActionID)
    }

    func testWhenInitialized_itStartsNewSession() throws {
        let expectation = self.expectation(description: "onSessionStart is called")
        let onSessionStart: RUM.SessionListener = { sessionId, isDiscarded in
            XCTAssertTrue(sessionId.matches(regex: .uuidRegex))
            XCTAssertTrue(isDiscarded)
            expectation.fulfill()
        }

        // When
        let scope = createRUMApplicationScope(
            dependencies: .mockWith(
                sessionSampler: .mockRejectAll(),
                onSessionStart: onSessionStart
            )
        )

        waitForExpectations(timeout: 0.5)

        // Then
        let session = try XCTUnwrap(scope.activeSession)
        XCTAssertTrue(session.isInitialSession, "Starting the very first view in application must create initial session")
    }

    func testWhenSessionExpires_itStartsANewOneAndTransfersActiveViews() throws {
        let expectation = self.expectation(description: "onSessionStart is called twice")
        expectation.expectedFulfillmentCount = 2

        let onSessionStart: RUM.SessionListener = { sessionId, isDiscarded in
            XCTAssertTrue(sessionId.matches(regex: .uuidRegex))
            XCTAssertFalse(isDiscarded)
            expectation.fulfill()
        }

        // Given
        var currentTime = Date()
        let scope = createRUMApplicationScope(
            dependencies: .mockWith(
                onSessionStart: onSessionStart
            )
        )

        let view = createMockViewInWindow()

        _ = scope.process(
            command: RUMStartViewCommand.mockWith(time: currentTime, identity: ViewIdentifier(view)),
            context: .mockAny(),
            writer: writer
        )

        let initialSession = try XCTUnwrap(scope.activeSession)

        // When
        // Push time forward by the max session duration:
        currentTime.addTimeInterval(RUMSessionScope.Constants.sessionMaxDuration)
        _ = scope.process(
            command: RUMAddUserActionCommand.mockWith(time: currentTime),
            context: .mockAny(),
            writer: writer
        )

        // Then
        waitForExpectations(timeout: 0.5)

        let nextSession = try XCTUnwrap(scope.activeSession)
        XCTAssertNotEqual(initialSession.sessionUUID, nextSession.sessionUUID, "New session must have different id")
        XCTAssertEqual(initialSession.viewScopes.count, nextSession.viewScopes.count, "All view scopes must be transferred to the new session")

        let initialViewScope = try XCTUnwrap(initialSession.viewScopes.first)
        let transferredViewScope = try XCTUnwrap(nextSession.viewScopes.first)
        XCTAssertNotEqual(initialViewScope.viewUUID, transferredViewScope.viewUUID, "Transferred view scope must have different view id")
        XCTAssertTrue(transferredViewScope.identity == ViewIdentifier(view), "Transferred view scope must track the same view")
        XCTAssertFalse(nextSession.isInitialSession, "Any next session in the application must be marked as 'not initial'")
    }

    // MARK: - RUM Session Sampling

    func testWhenSamplingRateIs100_allEventsAreSent() {
        let currentTime = Date()
        let scope = createRUMApplicationScope(
            dependencies: .mockWith(
                sessionSampler: Sampler(samplingRate: 100)
            )
        )

        _ = scope.process(
            command: RUMStartViewCommand.mockWith(time: currentTime, identity: .mockViewIdentifier()),
            context: .mockAny(),
            writer: writer
        )
        _ = scope.process(
            command: RUMStopViewCommand.mockWith(time: currentTime, identity: .mockViewIdentifier()),
            context: .mockAny(),
            writer: writer
        )

        // Two extra because of the ApplicationLaunch view start / stop
        XCTAssertEqual(writer.events(ofType: RUMViewEvent.self).count, 4)
    }

    func testWhenSamplingRateIs0_noEventsAreSent() {
        let currentTime = Date()
        let scope = createRUMApplicationScope(
            dependencies: .mockWith(
                sessionSampler: Sampler(samplingRate: 0)
            )
        )

        _ = scope.process(
            command: RUMStartViewCommand.mockWith(time: currentTime, identity: .mockViewIdentifier()),
            context: .mockAny(),
            writer: writer
        )
        _ = scope.process(
            command: RUMStartViewCommand.mockWith(time: currentTime, identity: .mockViewIdentifier()),
            context: .mockAny(),
            writer: writer
        )

        XCTAssertEqual(writer.events(ofType: RUMViewEvent.self).count, 0)
    }

    func testWhenSamplingRateIs50_onlyHalfOfTheEventsAreSent() throws {
        var currentTime = Date()
        let scope = createRUMApplicationScope(
            dependencies: .mockWith(
                sessionSampler: Sampler(samplingRate: 50)
            )
        )

        let simulatedSessionsCount = 400
        (0..<simulatedSessionsCount).forEach { _ in
            _ = scope.process(
                command: RUMStartViewCommand.mockWith(time: currentTime, identity: .mockViewIdentifier()),
                context: .mockAny(),
                writer: writer
            )
            _ = scope.process(
                command: RUMStopViewCommand.mockWith(time: currentTime, identity: .mockViewIdentifier()),
                context: .mockAny(),
                writer: writer
            )
            currentTime.addTimeInterval(RUMSessionScope.Constants.sessionTimeoutDuration) // force the Session to be re-created
        }

        let viewEventsCount = writer.events(ofType: RUMViewEvent.self).count
        let trackedSessionsCount = Double(viewEventsCount) / 2 // each Session should send 2 View updates

        let halfSessionsCount = 0.5 * Double(simulatedSessionsCount)
        XCTAssertGreaterThan(trackedSessionsCount, halfSessionsCount * 0.8) // -20%
        XCTAssertLessThan(trackedSessionsCount, halfSessionsCount * 1.2) // +20%
    }

    // MARK: - Stopping and Restarting Sessions

    func testWhenStoppingSession_itHasNoActiveSesssion() throws {
        // Given
        let currentTime = Date()
        let scope = createRUMApplicationScope(
            dependencies: .mockWith(
                sessionSampler: .mockRandom() // no matter sampling
            )
        )

        let command = RUMStartResourceCommand.mockWith(time: currentTime.addingTimeInterval(1))
        _ = scope.process(command: command, context: .mockAny(), writer: writer)

        // When
        let stopCommand = RUMStopSessionCommand.mockAny()
        _ = scope.process(command: stopCommand, context: .mockAny(), writer: writer)

        // Then
        XCTAssertNil(scope.activeSession)
    }

    // MARK: - Forced session

    func testGivenUncollectedSession_whenForced_itEndsItSoACollectedOneReplacesIt() throws {
        // Given: a session the draw threw away
        let currentTime = Date()
        let scope = createRUMApplicationScope(dependencies: .mockWith(sessionSampler: .mockRejectAll()))
        _ = scope.process(
            command: RUMCommandMock(time: currentTime.addingTimeInterval(1), isUserInteraction: true),
            context: .mockAny(),
            writer: writer
        )
        XCTAssertEqual(scope.activeSession?.isSampled, false)

        // When
        _ = scope.process(
            command: RUMSetForcedSessionCommand(time: currentTime.addingTimeInterval(2)),
            context: .mockAny(),
            writer: writer
        )

        // Then: the uncollected session is gone, and the next interaction starts a forced one
        XCTAssertTrue(scope.isForcedSession)
        XCTAssertNil(scope.activeSession)

        _ = scope.process(
            command: RUMCommandMock(time: currentTime.addingTimeInterval(3), isUserInteraction: true),
            context: .mockAny(),
            writer: writer
        )
        XCTAssertEqual(scope.activeSession?.isSampled, true, "the replacement session is collected despite a 0% draw")
        XCTAssertEqual(scope.activeSession?.isForced, true)
    }

    func testGivenCollectedSession_whenForced_itKeepsRunning() throws {
        // RUM cannot retro-collect what a running session already dropped, so cutting a session
        // that is already being collected in two would gain nothing.
        let currentTime = Date()
        let scope = createRUMApplicationScope(dependencies: .mockWith(sessionSampler: .mockKeepAll()))
        _ = scope.process(
            command: RUMCommandMock(time: currentTime.addingTimeInterval(1), isUserInteraction: true),
            context: .mockAny(),
            writer: writer
        )
        let sessionBefore = try XCTUnwrap(scope.activeSession?.sessionUUID)

        _ = scope.process(
            command: RUMSetForcedSessionCommand(time: currentTime.addingTimeInterval(2)),
            context: .mockAny(),
            writer: writer
        )

        XCTAssertTrue(scope.isForcedSession)
        XCTAssertEqual(scope.activeSession?.sessionUUID, sessionBefore, "the running session is untouched")
    }

    func testForcedStateOutlivesTheSessionThatSetIt() throws {
        let currentTime = Date()
        let scope = createRUMApplicationScope(dependencies: .mockWith(sessionSampler: .mockRejectAll()))
        _ = scope.process(
            command: RUMCommandMock(time: currentTime.addingTimeInterval(1), isUserInteraction: true),
            context: .mockAny(),
            writer: writer
        )
        _ = scope.process(
            command: RUMSetForcedSessionCommand(time: currentTime.addingTimeInterval(2)),
            context: .mockAny(),
            writer: writer
        )
        _ = scope.process(
            command: RUMCommandMock(time: currentTime.addingTimeInterval(3), isUserInteraction: true),
            context: .mockAny(),
            writer: writer
        )

        // A later stop must not hand the visitor back to the 0% draw: the forced state is
        // process-lifetime, decided again only on the next launch.
        _ = scope.process(
            command: RUMStopSessionCommand.mockWith(time: currentTime.addingTimeInterval(4)),
            context: .mockAny(),
            writer: writer
        )
        _ = scope.process(
            command: RUMCommandMock(time: currentTime.addingTimeInterval(5), isUserInteraction: true),
            context: .mockAny(),
            writer: writer
        )

        XCTAssertEqual(scope.activeSession?.isSampled, true)
    }

    func testGivenNoSession_whenForced_itStartsOneForcedRatherThanBuildingAndDiscardingOne() throws {
        // The flag has to be set before the flow that starts a session for any command reaches it.
        // Otherwise this command draws an ordinary session and then immediately throws it away —
        // one stopped session on the record, and the session that replaces it reporting itself as
        // following an explicit stop.
        let currentTime = Date()
        let scope = createRUMApplicationScope(dependencies: .mockWith(sessionSampler: .mockRejectAll()))
        _ = scope.process(
            command: RUMCommandMock(time: currentTime.addingTimeInterval(1), isUserInteraction: true),
            context: .mockAny(),
            writer: writer
        )
        _ = scope.process(
            command: RUMStopSessionCommand.mockWith(time: currentTime.addingTimeInterval(2)),
            context: .mockAny(),
            writer: writer
        )
        XCTAssertNil(scope.activeSession, "the ground state for this test: nothing running")

        // When: forcing is turned on with no session to act on
        _ = scope.process(
            command: RUMSetForcedSessionCommand(time: currentTime.addingTimeInterval(3)),
            context: .mockAny(),
            writer: writer
        )

        XCTAssertTrue(scope.isForcedSession)
        let session = try XCTUnwrap(scope.activeSession, "the command started a session rather than leaving none")
        XCTAssertTrue(session.isForced, "the session this command started is itself forced")
        XCTAssertTrue(session.isSampled, "so it is not drawn away by a 0% rate and replaced")
    }

    // MARK: - Remote sampling changed

    func testGivenOrdinarySession_whenRatesChangeImmediately_itEndsSoTheNextOneIsDrawnAnew() throws {
        let currentTime = Date()
        let scope = createRUMApplicationScope(dependencies: .mockWith(sessionSampler: .mockKeepAll()))
        _ = scope.process(
            command: RUMCommandMock(time: currentTime.addingTimeInterval(1), isUserInteraction: true),
            context: .mockAny(),
            writer: writer
        )
        XCTAssertNotNil(scope.activeSession)

        _ = scope.process(
            command: RUMRemoteSamplingChangedCommand(activation: .immediate, time: currentTime.addingTimeInterval(2)),
            context: .mockAny(),
            writer: writer
        )

        XCTAssertNil(scope.activeSession, "the session ends so the next one is drawn under the new rates")
    }

    func testGivenNoSession_whenRatesChangeImmediately_itStartsNothingToStop() throws {
        // The rates reach the core before this signal does, so anything started from here on is
        // already drawn under them. Ending a session this command itself started would leave a
        // stopped session on the record and hand the visitor a second one for no reason.
        let currentTime = Date()
        let scope = createRUMApplicationScope(dependencies: .mockWith(sessionSampler: .mockKeepAll()))
        _ = scope.process(
            command: RUMCommandMock(time: currentTime.addingTimeInterval(1), isUserInteraction: true),
            context: .mockAny(),
            writer: writer
        )
        _ = scope.process(
            command: RUMStopSessionCommand.mockWith(time: currentTime.addingTimeInterval(2)),
            context: .mockAny(),
            writer: writer
        )
        XCTAssertNil(scope.activeSession, "the ground state for this test: nothing running")

        _ = scope.process(
            command: RUMRemoteSamplingChangedCommand(activation: .immediate, time: currentTime.addingTimeInterval(3)),
            context: .mockAny(),
            writer: writer
        )

        XCTAssertNil(scope.activeSession, "nothing was running, so nothing was started and nothing was ended")
    }

    func testGivenSessionDrawnAtZero_whenTheRateRises_itEndsSoTheVisitorCanBeCollected() throws {
        // The case where the console is the only thing that ever turns collection on: an
        // application built at 0 shows the operator nothing until its sessions happen to rotate,
        // and nothing is indistinguishable from broken. Ending this one costs nothing — drawn at 0
        // it has no id, no events and no history, so it does not exist in the data at all.
        let currentTime = Date()
        let scope = scopeWithSessionDrawn(
            under: RemoteSamplingRates(sessionSampleRate: 0, version: 1),
            thenRatesBecome: RemoteSamplingRates(sessionSampleRate: 50, version: 2),
            at: currentTime
        )
        XCTAssertEqual(scope.activeSession?.isSampled, false, "the ground state: drawn at 0, collecting nothing")

        announceRatesChanged(to: scope, at: currentTime)

        XCTAssertNil(scope.activeSession, "the next session is drawn under the rate the operator just set")
    }

    func testGivenSessionDrawnAtARealRate_whenTheRateRises_theRunningSessionIsLeftAlone() throws {
        // The negative control, and the reason the rule reads the rate the session was DRAWN at
        // rather than whether it is being collected. Re-drawing only the sessions that lost, while
        // leaving the ones that won alone, spares the winners and re-rolls the losers: a fleet
        // drawn at 20 and moved to 50 would come out at 60. Zero is the only rate with no winners
        // to spare, which is why it is the only one acted on.
        //
        // The assertion holds whichever way this session's own draw at 20 fell, so nothing here
        // rides on a coin flip.
        let currentTime = Date()
        let scope = scopeWithSessionDrawn(
            under: RemoteSamplingRates(sessionSampleRate: 20, version: 1),
            thenRatesBecome: RemoteSamplingRates(sessionSampleRate: 50, version: 2),
            at: currentTime
        )
        let sessionBefore = try XCTUnwrap(scope.activeSession?.sessionUUID)

        announceRatesChanged(to: scope, at: currentTime)

        XCTAssertEqual(scope.activeSession?.sessionUUID, sessionBefore)
    }

    func testGivenForcingTurnedOn_whenRatesChangeImmediately_theRunningSessionIsKept() throws {
        // A forced session is collected whatever the rates say, so ending it would only buy
        // another forced session that behaves identically — at the cost of cutting the recording
        // somebody turned forcing on in order to watch.
        let currentTime = Date()
        let scope = createRUMApplicationScope(dependencies: .mockWith(sessionSampler: .mockKeepAll()))
        _ = scope.process(
            command: RUMCommandMock(time: currentTime.addingTimeInterval(1), isUserInteraction: true),
            context: .mockAny(),
            writer: writer
        )
        _ = scope.process(
            command: RUMSetForcedSessionCommand(time: currentTime.addingTimeInterval(2)),
            context: .mockAny(),
            writer: writer
        )
        let sessionBefore = try XCTUnwrap(scope.activeSession?.sessionUUID)

        _ = scope.process(
            command: RUMRemoteSamplingChangedCommand(activation: .immediate, time: currentTime.addingTimeInterval(3)),
            context: .mockAny(),
            writer: writer
        )

        XCTAssertEqual(scope.activeSession?.sessionUUID, sessionBefore, "the forced session is untouched")
    }

    // MARK: - Remote sampling changed: a rate of zero

    /// A session drawn under `first`, then told the rates are now `second`.
    private func scopeWithSessionDrawn(
        under first: RemoteSamplingRates?,
        thenRatesBecome second: RemoteSamplingRates?,
        at currentTime: Date,
        initialSampleRate: SampleRate = 100,
        forced: Bool = false
    ) -> RUMApplicationScope {
        var rates = first
        let scope = createRUMApplicationScope(
            dependencies: .mockWith(
                sessionSampler: Sampler(samplingRate: initialSampleRate),
                remoteSamplingRates: { rates }
            )
        )
        _ = scope.process(
            command: RUMCommandMock(time: currentTime.addingTimeInterval(1), isUserInteraction: true),
            context: .mockAny(),
            writer: writer
        )
        if forced {
            _ = scope.process(
                command: RUMSetForcedSessionCommand(time: currentTime.addingTimeInterval(2)),
                context: .mockAny(),
                writer: writer
            )
        }
        rates = second
        return scope
    }

    private func announceRatesChanged(to scope: RUMApplicationScope, at currentTime: Date) {
        _ = scope.process(
            command: RUMRemoteSamplingChangedCommand(activation: .nextSession, time: currentTime.addingTimeInterval(3)),
            context: .mockAny(),
            writer: writer
        )
    }

    func testGivenCollectedSession_whenTheRateBecomesZero_itEndsWithoutTheConsoleAskingItTo() throws {
        // Zero is the one rate that answers "should this session still be kept" on its own, so it
        // needs no `immediate` instruction. Waiting for the session to rotate could take hours, and
        // "stop collecting" is the one request where hours is the wrong answer.
        let currentTime = Date()
        let scope = scopeWithSessionDrawn(
            under: RemoteSamplingRates(sessionSampleRate: 100, version: 1),
            thenRatesBecome: RemoteSamplingRates(sessionSampleRate: 0, version: 2),
            at: currentTime
        )
        XCTAssertEqual(scope.activeSession?.isSampled, true, "the session under test has to be one that is collecting")

        announceRatesChanged(to: scope, at: currentTime)

        XCTAssertNil(scope.activeSession, "a session that was collecting stops collecting now")
    }

    func testGivenUncollectedSession_whenTheRateBecomesZero_nothingIsStopped() throws {
        // Ending it would gain nothing and cost something: a stopped session on the record, and a
        // replacement that reports itself as following an explicit stop.
        let currentTime = Date()
        let zero = RemoteSamplingRates(sessionSampleRate: 0, version: 1)
        let scope = scopeWithSessionDrawn(under: zero, thenRatesBecome: zero, at: currentTime)
        let sessionBefore = try XCTUnwrap(scope.activeSession)
        XCTAssertFalse(sessionBefore.isSampled, "the session under test has to be one that is not collecting")

        announceRatesChanged(to: scope, at: currentTime)

        XCTAssertEqual(scope.activeSession?.sessionUUID, sessionBefore.sessionUUID)
    }

    func testWhenTheRateChangesToAnythingButZero_theRunningSessionIsLeftAlone() throws {
        // Any other rate is silent about this session: whether it should still be kept can only be
        // answered by drawing again, and drawing twice is not the same as drawing once.
        let currentTime = Date()
        let scope = scopeWithSessionDrawn(
            under: RemoteSamplingRates(sessionSampleRate: 100, version: 1),
            thenRatesBecome: RemoteSamplingRates(sessionSampleRate: 30, version: 2),
            at: currentTime
        )
        let sessionBefore = try XCTUnwrap(scope.activeSession?.sessionUUID)

        announceRatesChanged(to: scope, at: currentTime)

        XCTAssertEqual(scope.activeSession?.sessionUUID, sessionBefore)
    }

    func testGivenForcingTurnedOn_whenTheRateBecomesZero_theRunningSessionIsKept() throws {
        let currentTime = Date()
        let scope = scopeWithSessionDrawn(
            under: RemoteSamplingRates(sessionSampleRate: 100, version: 1),
            thenRatesBecome: RemoteSamplingRates(sessionSampleRate: 0, version: 2),
            at: currentTime,
            forced: true
        )
        let sessionBefore = try XCTUnwrap(scope.activeSession?.sessionUUID)

        announceRatesChanged(to: scope, at: currentTime)

        XCTAssertEqual(scope.activeSession?.sessionUUID, sessionBefore, "forcing outranks the rates")
    }

    func testWhenTheConsoleClearsTheRate_theValueTheAppWasInitialisedWithDecides() throws {
        // The console can clear a knob as well as set it, and clearing it hands the decision back
        // to the init value — which the core never sees. This is why the question is answered here
        // and not where the response is parsed.
        let currentTime = Date()
        let scope = scopeWithSessionDrawn(
            under: RemoteSamplingRates(sessionSampleRate: 100, version: 1),
            thenRatesBecome: RemoteSamplingRates(sessionSampleRate: nil, version: 2),
            at: currentTime,
            initialSampleRate: 0
        )
        XCTAssertEqual(scope.activeSession?.isSampled, true)

        announceRatesChanged(to: scope, at: currentTime)

        XCTAssertNil(scope.activeSession, "with the knob cleared the init value applies, and it is zero")
    }

    func testGivenStoppedSession_whenUserActionEvent_itStartsANewSession() throws {
        // Given
        let currentTime = Date()
        let scope = createRUMApplicationScope(
            dependencies: .mockWith(
                sessionSampler: .mockKeepAll()
            )
        )
        _ = scope.process(
            command: RUMCommandMock(time: currentTime.addingTimeInterval(1), isUserInteraction: true),
            context: .mockAny(),
            writer: writer
        )
        _ = scope.process(
            command: RUMStopSessionCommand.mockWith(time: currentTime.addingTimeInterval(2)),
            context: .mockAny(),
            writer: writer
        )

        // When
        _ = scope.process(
            command: RUMCommandMock(time: currentTime.addingTimeInterval(3), isUserInteraction: true),
            context: .mockAny(),
            writer: writer
        )

        // Then
        XCTAssertEqual(scope.sessionScopes.count, 1)
        XCTAssertNotNil(scope.activeSession)
    }

    func testGivenSessionProcessingResources_whenStopped_itStaysInactive() throws {
        // Given
        let currentTime = Date()
        let scope = createRUMApplicationScope(
            dependencies: .mockWith(
                sessionSampler: .mockKeepAll()
            )
        )
        _ = scope.process(
            command: RUMStartResourceCommand.mockRandom(),
            context: .mockAny(),
            writer: writer
        )

        // When
        _ = scope.process(
            command: RUMStopSessionCommand.mockWith(time: currentTime.addingTimeInterval(2)),
            context: .mockAny(),
            writer: writer
        )

        // Then
        XCTAssertEqual(scope.sessionScopes.count, 1)
        XCTAssertNil(scope.activeSession)
    }

    func testGivenSessionProcessingResources_whenStopped_itIsRemovedWhenResourceFinishes() throws {
        // Given
        let currentTime = Date()
        let scope = createRUMApplicationScope(
            dependencies: .mockWith(
                sessionSampler: .mockKeepAll()
            )
        )
        let resourceKey = "resources/1"
        _ = scope.process(
            command: RUMStartResourceCommand.mockWith(
                resourceKey: resourceKey,
                time: currentTime.addingTimeInterval(1)
            ),
            context: .mockAny(),
            writer: writer
        )

        // When
        let firstSession = try XCTUnwrap(scope.activeSession)
        _ = scope.process(
            command: RUMStopSessionCommand.mockWith(time: currentTime.addingTimeInterval(2)),
            context: .mockAny(),
            writer: writer
        )
        XCTAssertEqual(scope.sessionScopes.count, 1)
        _ = scope.process(
            command: RUMCommandMock(time: currentTime.addingTimeInterval(3), isUserInteraction: true),
            context: .mockAny(),
            writer: writer
        )
        XCTAssertEqual(scope.sessionScopes.count, 2)
        let secondSession = try XCTUnwrap(scope.activeSession)
        _ = scope.process(
            command: RUMStopResourceCommand.mockWith(
                resourceKey: resourceKey,
                time: currentTime.addingTimeInterval(4)
            ),
            context: .mockAny(),
            writer: writer
        )

        // Then
        XCTAssertNotEqual(firstSession.sessionUUID, secondSession.sessionUUID)
        XCTAssertEqual(scope.sessionScopes.count, 1)
        XCTAssertEqual(scope.activeSession?.sessionUUID, secondSession.sessionUUID)
    }

    // MARK: - Starting Session With Different Preconditions

    func testGivenAppLaunchInForegroundAndNoPrewarming_whenInitialSessionIsStarted() throws {
        // Given
        let sdkContext: DatadogContext = .mockWith(
            launchInfo: .mockWith(
                launchReason: .userLaunch,
                processLaunchDate: .mockDecember15th2019At10AMUTC()
            ),
            applicationStateHistory: .mockAppInForeground(since: .mockDecember15th2019At10AMUTC())
        )

        // When
        let scope = createRUMApplicationScope(
            dependencies: .mockWith(sessionSampler: .mockKeepAll()),
            sdkContext: sdkContext
        )

        // Then
        let session = try XCTUnwrap(scope.activeSession)
        let view = try XCTUnwrap(session.viewScopes.first)
        XCTAssertEqual(
            session.context.sessionPrecondition,
            .userAppLaunch,
            "It should set 'user app launch' precondition"
        )
        XCTAssertEqual(
            view.viewName,
            RUMOffViewEventsHandlingRule.Constants.applicationLaunchViewName,
            "It should start 'application launch' view"
        )
    }

    func testGivenAppLaunchInBackgroundAndNoPrewarming_whenInitialSessionIsStarted() throws {
        // Given
        let sdkContext: DatadogContext = .mockWith(
            launchInfo: .mockWith(
                launchReason: .backgroundLaunch,
                processLaunchDate: .mockDecember15th2019At10AMUTC()
            ),
            applicationStateHistory: .mockAppInBackground(since: .mockDecember15th2019At10AMUTC())
        )

        // When
        let scope = createRUMApplicationScope(
            dependencies: .mockWith(sessionSampler: .mockKeepAll()),
            sdkContext: sdkContext
        )

        // Then
        let session = try XCTUnwrap(scope.activeSession)
        XCTAssertEqual(
            session.context.sessionPrecondition,
            .backgroundLaunch,
            "It should set 'background launch' precondition"
        )
        XCTAssertTrue(
            session.viewScopes.isEmpty,
            "It should not start any view"
        )
    }

    func testGivenLaunchWithPrewarming_whenInitialSessionIsStarted() throws {
        // Given
        let sdkContext: DatadogContext = .mockWith(
            launchInfo: .mockWith(
                launchReason: .prewarming,
                processLaunchDate: .mockDecember15th2019At10AMUTC()
            ),
            applicationStateHistory: .mockWith(initialState: .background, date: .mockDecember15th2019At10AMUTC())
        )

        // When
        let scope = createRUMApplicationScope(
            dependencies: .mockWith(sessionSampler: .mockKeepAll()),
            sdkContext: sdkContext
        )

        // Then
        let session = try XCTUnwrap(scope.activeSession)
        XCTAssertEqual(
            session.context.sessionPrecondition,
            .prewarm,
            "It should set 'prewarm' precondition"
        )
        XCTAssertTrue(
            session.viewScopes.isEmpty,
            "It should not start any view"
        )
    }

    func testGivenInactiveSession_whenNewOneIsStarted_itSetsInactivityTimeoutPrecondition() {
        // Given
        var currentTime: Date = .mockDecember15th2019At10AMUTC()
        let sdkContext: DatadogContext = .mockWith(sdkInitDate: currentTime)
        let scope = createRUMApplicationScope(
            dependencies: .mockWith(sessionSampler: .mockKeepAll()),
            sdkContext: sdkContext
        )

        // When
        currentTime.addTimeInterval(RUMSessionScope.Constants.sessionTimeoutDuration)
        _ = scope.process(
            command: RUMCommandMock(time: currentTime, isUserInteraction: true),
            context: sdkContext,
            writer: writer
        )

        // Then
        XCTAssertEqual(scope.activeSession?.context.sessionPrecondition, .inactivityTimeout)
    }

    func testGivenExpiredSession_whenNewOneIsStarted_itSetsMaxDurationPrecondition() {
        // Given
        let initialTime: Date = .mockDecember15th2019At10AMUTC()
        var currentTime: Date = initialTime
        let sdkContext: DatadogContext = .mockWith(sdkInitDate: currentTime)
        let scope = createRUMApplicationScope(
            dependencies: .mockWith(sessionSampler: .mockKeepAll()),
            sdkContext: sdkContext
        )

        // keep session active until it expires
        while currentTime < initialTime.addingTimeInterval(RUMSessionScope.Constants.sessionMaxDuration) {
            currentTime.addTimeInterval(RUMSessionScope.Constants.sessionTimeoutDuration - 1)
            _ = scope.process(
                command: RUMCommandMock(time: currentTime, isUserInteraction: true),
                context: sdkContext,
                writer: writer
            )
        }

        // When
        _ = scope.process(
            command: RUMCommandMock(time: currentTime, isUserInteraction: true),
            context: sdkContext,
            writer: writer
        )

        // Then
        XCTAssertEqual(scope.activeSession?.context.sessionPrecondition, .maxDuration)
    }

    func testGivenStoppedSession_whenNewOneIsStarted_itSetsExplicitStopPrecondition() {
        // Given
        var currentTime: Date = .mockDecember15th2019At10AMUTC()
        let sdkContext: DatadogContext = .mockWith(sdkInitDate: currentTime)
        let scope = createRUMApplicationScope(
            dependencies: .mockWith(sessionSampler: .mockKeepAll()),
            sdkContext: sdkContext
        )

        currentTime.addTimeInterval(1)
        _ = scope.process(command: RUMStopSessionCommand(time: currentTime), context: sdkContext, writer: writer)

        // When
        currentTime.addTimeInterval(1)
        _ = scope.process(
            command: RUMCommandMock(time: currentTime, isUserInteraction: true),
            context: sdkContext,
            writer: writer
        )

        // Then
        XCTAssertEqual(scope.activeSession?.context.sessionPrecondition, .explicitStop)
    }
}
