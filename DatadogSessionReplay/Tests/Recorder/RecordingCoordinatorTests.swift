/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

#if os(iOS)
import XCTest
@testable import DatadogInternal
@_spi(Internal)
@testable import DatadogSessionReplay
@testable import TestUtilities

class RecordingCoordinatorTests: XCTestCase {
    private var core: PassthroughCoreMock! // swiftlint:disable:this implicitly_unwrapped_optional
    var recordingCoordinator: RecordingCoordinator?

    private var recordingMock = RecordingMock()
    private var scheduler = TestScheduler()
    private var rumContextObserver = RUMContextObserverMock()
    private lazy var contextPublisher: SRContextPublisher = {
        SRContextPublisher(core: core)
    }()

    override func setUpWithError() throws {
        core = PassthroughCoreMock()
    }

    override func tearDown() {
        core = nil
        XCTAssertEqual(PassthroughCoreMock.referenceCount, 0)
    }

    // MARK: Configuration Tests

    func test_itDoesNotStartScheduler_afterInitializing() {
        prepareRecordingCoordinator(sampler: Sampler(samplingRate: .mockRandom(min: 0, max: 100)))
        XCTAssertFalse(scheduler.isRunning)
        XCTAssertEqual(recordingMock.captureNextRecordCallsCount, 0)
    }

    func test_whenNotSampled_itStopsScheduler_andShouldNotRecord() throws {
        // Given
        prepareRecordingCoordinator(sampler: .mockRejectAll())

        // When
        rumContextObserver.notify(rumContext: .mockRandom())

        // Then
        let hasReplay = try XCTUnwrap(core.context.additionalContext(ofType: SessionReplayCoreContext.HasReplay.self))
        XCTAssertFalse(scheduler.isRunning)
        XCTAssertFalse(hasReplay.value)
        XCTAssertEqual(recordingMock.captureNextRecordCallsCount, 0)
    }

    // MARK: - FLASHCAT FORK - forced sessions

    func test_whenTheSessionWasForced_itRecordsEvenThoughReplaysOwnDrawSaidNo() throws {
        // Forcing exists to watch one visitor. A recording of them without the replay is not the
        // thing that was asked for, so the host application's decision outranks replay's own draw.
        prepareRecordingCoordinator(sampler: .mockRejectAll())

        rumContextObserver.notify(rumContext: RUMCoreContext(applicationID: "app", sessionID: "session", sessionForced: true))

        let hasReplay = try XCTUnwrap(core.context.additionalContext(ofType: SessionReplayCoreContext.HasReplay.self))
        XCTAssertTrue(scheduler.isRunning)
        XCTAssertTrue(hasReplay.value)
    }

    func test_whenTheSessionWasNotForced_replaysOwnDrawStillDecides() throws {
        // The negative control for the test above: without the flag, a rejecting sampler rejects.
        prepareRecordingCoordinator(sampler: .mockRejectAll())

        rumContextObserver.notify(rumContext: RUMCoreContext(applicationID: "app", sessionID: "session", sessionForced: false))

        let hasReplay = try XCTUnwrap(core.context.additionalContext(ofType: SessionReplayCoreContext.HasReplay.self))
        XCTAssertFalse(scheduler.isRunning)
        XCTAssertFalse(hasReplay.value)
    }

    func test_whenSampled_itStartsScheduler_andShouldRecord() throws {
        // Given
        let textAndInputPrivacy = TextAndInputPrivacyLevel.mockRandom()
        let imagePrivacy = ImagePrivacyLevel.mockRandom()
        let touchPrivacy = TouchPrivacyLevel.mockRandom()
        prepareRecordingCoordinator(textAndInputPrivacy: textAndInputPrivacy, imagePrivacy: imagePrivacy, touchPrivacy: touchPrivacy)

        // When
        let rumContext: RUMCoreContext = .mockRandom()
        rumContextObserver.notify(rumContext: rumContext)

        // Then
        let hasReplay = try XCTUnwrap(core.context.additionalContext(ofType: SessionReplayCoreContext.HasReplay.self))
        XCTAssertTrue(scheduler.isRunning)
        XCTAssertTrue(hasReplay.value)
        XCTAssertEqual(recordingMock.captureNextRecordReceivedRecorderContext?.applicationID, rumContext.applicationID)
        XCTAssertEqual(recordingMock.captureNextRecordReceivedRecorderContext?.sessionID, rumContext.sessionID)
        XCTAssertEqual(recordingMock.captureNextRecordReceivedRecorderContext?.viewID, rumContext.viewID)
        XCTAssertEqual(recordingMock.captureNextRecordReceivedRecorderContext?.viewServerTimeOffset, rumContext.viewServerTimeOffset)
        XCTAssertEqual(recordingMock.captureNextRecordReceivedRecorderContext?.textAndInputPrivacy, textAndInputPrivacy)
        XCTAssertEqual(recordingMock.captureNextRecordReceivedRecorderContext?.imagePrivacy, imagePrivacy)
        XCTAssertEqual(recordingMock.captureNextRecordReceivedRecorderContext?.touchPrivacy, touchPrivacy)
        XCTAssertEqual(recordingMock.captureNextRecordCallsCount, 1)
    }

    func test_whenEmptyRUMContext_itShouldNotRecord() {
        // Given
        prepareRecordingCoordinator(sampler: Sampler(samplingRate: .mockRandom(min: 0, max: 100)))

        // When
        rumContextObserver.notify(rumContext: nil)

        // Then
        XCTAssertEqual(recordingMock.captureNextRecordCallsCount, 0)
    }

    func test_whenNoRUMContext_itShouldNotRecord() throws {
        // Given
        prepareRecordingCoordinator(sampler: Sampler(samplingRate: .mockRandom(min: 0, max: 100)))

        // Then
        let hasReplay = try XCTUnwrap(core.context.additionalContext(ofType: SessionReplayCoreContext.HasReplay.self))
        XCTAssertFalse(scheduler.isRunning)
        XCTAssertFalse(hasReplay.value)
        XCTAssertEqual(recordingMock.captureNextRecordCallsCount, 0)
    }

    func test_whenRUMContextWithoutViewID_itShouldRecord_itShouldNotCaptureSnapshots() throws {
        // Given
        prepareRecordingCoordinator()

        // When
        let rumContext: RUMCoreContext = .mockWith(viewID: nil)
        rumContextObserver.notify(rumContext: rumContext)

        // Then
        let hasReplay = try XCTUnwrap(core.context.additionalContext(ofType: SessionReplayCoreContext.HasReplay.self))
        XCTAssertTrue(scheduler.isRunning)
        XCTAssertTrue(hasReplay.value)
        XCTAssertEqual(recordingMock.captureNextRecordCallsCount, 0)
    }

    // MARK: Telemetry Tests

    func test_whenCapturingSnapshotFails_itSendsErrorTelemetry() {
        let telemetry = TelemetryMock()

        // Given
        recordingMock.captureNextRecordClosure = { _ in
            throw ErrorMock("snapshot creation error")
        }

        prepareRecordingCoordinator(telemetry: telemetry)

        // When
        rumContextObserver.notify(rumContext: .mockRandom())

        // Then
        let error = telemetry.messages.firstError()
        XCTAssertEqual(error?.message, "[SR] Failed to take snapshot - snapshot creation error")
        XCTAssertEqual(error?.kind, "ErrorMock")
        XCTAssertEqual(error?.stack, "snapshot creation error")
    }

    func test_whenCapturingSnapshotFails_withObjCRuntimeException_itSendsErrorTelemetry() {
        let telemetry = TelemetryMock()

        // Given
        recordingMock.captureNextRecordClosure = { _ in
            throw ObjcException(error: ErrorMock("snapshot creation error"), file: "File.swift", line: 0)
        }

        prepareRecordingCoordinator(telemetry: telemetry)

        // When
        rumContextObserver.notify(rumContext: .mockRandom())

        // Then
        let error = telemetry.messages.firstError()
        XCTAssertEqual(error?.message, "[SR] Failed to take snapshot due to Objective-C runtime exception - snapshot creation error")
        XCTAssertEqual(error?.kind, "ErrorMock")
        XCTAssertEqual(error?.stack, "snapshot creation error")
        XCTAssertFalse(scheduler.isRunning)
    }

    func test_whenCapturingSnapshot_itSendsMethodCalledTelemetry() throws {
        // Given
        let telemetry = TelemetryMock()
        prepareRecordingCoordinator(
            telemetry: telemetry,
            methodCallTelemetrySamplingRate: 100
        )

        // When
        rumContextObserver.notify(rumContext: .mockRandom())

        // Then
        let metric = try XCTUnwrap(telemetry.messages.last?.asMetric)
        XCTAssertEqual(metric.name, "Method Called")
    }

    // MARK: StartRecordingImmediately Initialization Tests

    func test_whenStartRecordingImmediatelyIsDefault_itShouldRecord() throws {
        // Given
        prepareRecordingCoordinator()

        // When
        let rumContext: RUMCoreContext = .mockRandom()
        rumContextObserver.notify(rumContext: rumContext)

        // Then
        let hasReplay = try XCTUnwrap(core.context.additionalContext(ofType: SessionReplayCoreContext.HasReplay.self))
        XCTAssertTrue(scheduler.isRunning)
        XCTAssertTrue(hasReplay.value)
        XCTAssertEqual(recordingMock.captureNextRecordCallsCount, 1)
    }

    func test_whenStartRecordingImmediatelyIsTrue_itShouldRecord() throws {
        // Given
        prepareRecordingCoordinator(startRecordingImmediately: true)

        // When
        let rumContext: RUMCoreContext = .mockRandom()
        rumContextObserver.notify(rumContext: rumContext)

        // Then
        let hasReplay = try XCTUnwrap(core.context.additionalContext(ofType: SessionReplayCoreContext.HasReplay.self))
        XCTAssertTrue(scheduler.isRunning)
        XCTAssertTrue(hasReplay.value)
        XCTAssertEqual(recordingMock.captureNextRecordCallsCount, 1)
    }

    func test_whenStartRecordingImmediatelyIsFalse_shouldNotRecord() throws {
        // Given
        prepareRecordingCoordinator(startRecordingImmediately: false)

        // When
        let rumContext: RUMCoreContext = .mockRandom()
        rumContextObserver.notify(rumContext: rumContext)

        // Then
        let hasReplay = try XCTUnwrap(core.context.additionalContext(ofType: SessionReplayCoreContext.HasReplay.self))
        XCTAssertFalse(scheduler.isRunning)
        XCTAssertFalse(hasReplay.value)
        XCTAssertEqual(recordingMock.captureNextRecordCallsCount, 0)
    }

    // MARK: Start / Stop API Tests

    func test_whenStopRecording_shouldStopRecord() throws {
        // Given
        prepareRecordingCoordinator()
        let rumContext: RUMCoreContext = .mockRandom()
        rumContextObserver.notify(rumContext: rumContext)

        // When
        recordingCoordinator?.stopRecording()

        // Then
        let hasReplay = try XCTUnwrap(core.context.additionalContext(ofType: SessionReplayCoreContext.HasReplay.self))
        XCTAssertFalse(scheduler.isRunning)
        XCTAssertFalse(hasReplay.value)
    }

    func test_startRecording_whenAlreadyRecording_shouldRecord() throws {
        // Given
        prepareRecordingCoordinator()
        let rumContext: RUMCoreContext = .mockRandom()
        rumContextObserver.notify(rumContext: rumContext)
        recordingCoordinator?.startRecording()

        // When
        recordingCoordinator?.startRecording()

        // Then
        let hasReplay = try XCTUnwrap(core.context.additionalContext(ofType: SessionReplayCoreContext.HasReplay.self))
        XCTAssertTrue(scheduler.isRunning)
        XCTAssertTrue(hasReplay.value)
    }

    func test_stopRecording_whenAlreadyStopped_shouldNotRecord() throws {
        // Given
        prepareRecordingCoordinator()
        let rumContext: RUMCoreContext = .mockRandom()
        rumContextObserver.notify(rumContext: rumContext)
        recordingCoordinator?.stopRecording()

        // When
        recordingCoordinator?.stopRecording()

        // Then
        let hasReplay = try XCTUnwrap(core.context.additionalContext(ofType: SessionReplayCoreContext.HasReplay.self))
        XCTAssertFalse(scheduler.isRunning)
        XCTAssertFalse(hasReplay.value)
    }

    // MARK: - FLASHCAT FORK - replay kept on error

    private var errorReplay: SessionReplayCoreContext.ErrorReplay? {
        core.context.additionalContext(ofType: SessionReplayCoreContext.ErrorReplay.self)
    }

    private var hasReplay: Bool? {
        core.context.additionalContext(ofType: SessionReplayCoreContext.HasReplay.self)?.value
    }

    func test_aReplayTheDrawLeavesOut_isRecordedWithheld_whenKeptOnError() throws {
        prepareRecordingCoordinator(sampler: .mockRejectAll(), sessionReplayOnError: true)
        let rum = RUMCoreContext(applicationID: "a", sessionID: "s1", viewID: "v1")

        rumContextObserver.notify(rumContext: rum)

        XCTAssertTrue(scheduler.isRunning)
        XCTAssertEqual(recordingMock.captureNextRecordReceivedRecorderContext?.replayHold, .withheld)
        XCTAssertEqual(errorReplay, .init(sessionID: "s1", withheld: true))
        XCTAssertEqual(hasReplay, false, "a withheld replay may never be uploaded")
    }

    func test_control_withTheSwitchOff_aReplayTheDrawLeavesOutIsNotRecorded() {
        prepareRecordingCoordinator(sampler: .mockRejectAll(), sessionReplayOnError: false)

        rumContextObserver.notify(rumContext: RUMCoreContext(applicationID: "a", sessionID: "s1", viewID: "v1"))

        XCTAssertFalse(scheduler.isRunning)
        XCTAssertNil(errorReplay)
    }

    func test_aSampledReplay_isWithheldAlongsideTheEventsOfASessionKeptOnError() {
        prepareRecordingCoordinator(sampler: .mockKeepAll())

        rumContextObserver.notify(rumContext: RUMCoreContext(applicationID: "a", sessionID: "s1", viewID: "v1", eventsWithheld: true))

        XCTAssertEqual(recordingMock.captureNextRecordReceivedRecorderContext?.replayHold, .withheld)
        XCTAssertEqual(errorReplay, .init(sessionID: "s1", withheld: true))
    }

    func test_control_aSampledReplayOfACollectedSession_isNotWithheld() {
        prepareRecordingCoordinator(sampler: .mockKeepAll(), sessionReplayOnError: true)

        rumContextObserver.notify(rumContext: RUMCoreContext(applicationID: "a", sessionID: "s1", viewID: "v1"))

        XCTAssertEqual(recordingMock.captureNextRecordReceivedRecorderContext?.replayHold, Recorder.ReplayHold.none)
        XCTAssertNil(errorReplay)
        XCTAssertEqual(hasReplay, true)
    }

    func test_theSessionsError_releasesTheReplay() {
        prepareRecordingCoordinator(sampler: .mockRejectAll(), sessionReplayOnError: true)
        rumContextObserver.notify(rumContext: RUMCoreContext(applicationID: "a", sessionID: "s1", viewID: "v1"))
        let capturesBefore = recordingMock.captureNextRecordCallsCount

        rumContextObserver.notify(rumContext: RUMCoreContext(applicationID: "a", sessionID: "s1", viewID: "v1", hasReportedError: true))

        XCTAssertGreaterThan(recordingMock.captureNextRecordCallsCount, capturesBefore)
        XCTAssertEqual(recordingMock.captureNextRecordReceivedRecorderContext?.replayHold, Recorder.ReplayHold.none)
        XCTAssertEqual(errorReplay, .init(sessionID: "s1", withheld: false), "still a replay kept on error, no longer withheld")
        XCTAssertEqual(hasReplay, true)
    }

    func test_aReplayWithheldWithTheSessionsEvents_waitsForThoseEventsToBeOut() {
        // The error is reported before the events go out (they leave behind a jitter); until
        // they arrive the session does not exist, and a replay sent first has nothing to attach to.
        prepareRecordingCoordinator(sampler: .mockKeepAll())
        rumContextObserver.notify(rumContext: RUMCoreContext(applicationID: "a", sessionID: "s1", viewID: "v1", eventsWithheld: true))

        rumContextObserver.notify(rumContext: RUMCoreContext(applicationID: "a", sessionID: "s1", viewID: "v1", eventsWithheld: true, hasReportedError: true))
        XCTAssertEqual(errorReplay?.withheld, true)
        XCTAssertEqual(recordingMock.captureNextRecordReceivedRecorderContext?.replayHold, .releasePending, "still withheld, but nothing throws it away any more")

        rumContextObserver.notify(rumContext: RUMCoreContext(applicationID: "a", sessionID: "s1", viewID: "v1", eventsWithheld: false, hasReportedError: true))
        XCTAssertEqual(errorReplay?.withheld, false)
        XCTAssertEqual(recordingMock.captureNextRecordReceivedRecorderContext?.replayHold, Recorder.ReplayHold.none)
    }

    func test_theConsentTravelsWithTheRUMContext() {
        prepareRecordingCoordinator(sampler: .mockRejectAll(), sessionReplayOnError: true)

        rumContextObserver.notify(rumContext: RUMCoreContext(applicationID: "a", sessionID: "s1", viewID: "v1"), trackingConsent: .notGranted)
        XCTAssertEqual(recordingMock.captureNextRecordReceivedRecorderContext?.trackingConsent, .notGranted)

        rumContextObserver.notify(rumContext: RUMCoreContext(applicationID: "a", sessionID: "s1", viewID: "v1"), trackingConsent: .granted)
        XCTAssertEqual(recordingMock.captureNextRecordReceivedRecorderContext?.trackingConsent, .granted)
    }

    func test_whenConsentIsWithdrawn_theWithheldRecordsAreThrownAwayAtOnce() {
        // Not with the next snapshot: recording may be stopped and never take one.
        prepareRecordingCoordinator(sampler: .mockRejectAll(), sessionReplayOnError: true)
        let rum = RUMCoreContext(applicationID: "a", sessionID: "s1", viewID: "v1")
        rumContextObserver.notify(rumContext: rum, trackingConsent: .granted)
        XCTAssertEqual(recordingMock.discardWithheldRecordsCallsCount, 0)

        rumContextObserver.notify(rumContext: rum, trackingConsent: .notGranted)

        XCTAssertEqual(recordingMock.discardWithheldRecordsCallsCount, 1)
    }

    func test_whenTheSessionChanges_theWithheldRecordsAreThrownAwayAtOnce() {
        prepareRecordingCoordinator(sampler: .mockRejectAll(), sessionReplayOnError: true)
        rumContextObserver.notify(rumContext: RUMCoreContext(applicationID: "a", sessionID: "s1", viewID: "v1"))

        rumContextObserver.notify(rumContext: nil)
        XCTAssertEqual(recordingMock.discardWithheldRecordsCallsCount, 1, "the session ended")

        rumContextObserver.notify(rumContext: RUMCoreContext(applicationID: "a", sessionID: "s2", viewID: "v2"))
        rumContextObserver.notify(rumContext: RUMCoreContext(applicationID: "a", sessionID: "s3", viewID: "v3"))
        XCTAssertEqual(recordingMock.discardWithheldRecordsCallsCount, 2, "every change away from a session throws away whatever is still held")
    }

    func test_whenConsentIsWithdrawnAfterARelease_theRecordsStillHeldAreThrownAwayToo() {
        // A release only tells the processor to write with the next snapshot; with recording
        // stopped none is taken, so the records are still held when consent goes.
        prepareRecordingCoordinator(sampler: .mockRejectAll(), sessionReplayOnError: true)
        let rum = RUMCoreContext(applicationID: "a", sessionID: "s1", viewID: "v1")
        rumContextObserver.notify(rumContext: rum, trackingConsent: .granted)
        recordingCoordinator?.stopRecording()
        rumContextObserver.notify(rumContext: RUMCoreContext(applicationID: "a", sessionID: "s1", viewID: "v1", hasReportedError: true), trackingConsent: .granted)
        XCTAssertEqual(recordingMock.discardWithheldRecordsCallsCount, 0)

        rumContextObserver.notify(rumContext: RUMCoreContext(applicationID: "a", sessionID: "s1", viewID: "v1", hasReportedError: true), trackingConsent: .notGranted)

        XCTAssertEqual(recordingMock.discardWithheldRecordsCallsCount, 1)
    }

    func test_forcingTheSession_releasesTheReplay() {
        prepareRecordingCoordinator(sampler: .mockRejectAll(), sessionReplayOnError: true)
        rumContextObserver.notify(rumContext: RUMCoreContext(applicationID: "a", sessionID: "s1", viewID: "v1"))

        rumContextObserver.notify(rumContext: RUMCoreContext(applicationID: "a", sessionID: "s1", viewID: "v1", sessionForced: true))

        XCTAssertEqual(errorReplay?.withheld, false)
    }

    func test_forcingASessionWithoutReplay_startsRecordingIt() {
        prepareRecordingCoordinator(sampler: .mockRejectAll())
        rumContextObserver.notify(rumContext: RUMCoreContext(applicationID: "a", sessionID: "s1", viewID: "v1", eventsWithheld: true))
        XCTAssertFalse(scheduler.isRunning)

        rumContextObserver.notify(rumContext: RUMCoreContext(applicationID: "a", sessionID: "s1", viewID: "v1", sessionForced: true))

        XCTAssertTrue(scheduler.isRunning)
    }

    func test_control_forcingACollectedSessionWithoutReplay_doesNotStartRecordingIt() {
        // A session already under way is not re-decided: one collected without replay keeps
        // running without it, as `setForcedSession` documents.
        prepareRecordingCoordinator(sampler: .mockRejectAll())
        rumContextObserver.notify(rumContext: RUMCoreContext(applicationID: "a", sessionID: "s1", viewID: "v1"))
        XCTAssertFalse(scheduler.isRunning)

        rumContextObserver.notify(rumContext: RUMCoreContext(applicationID: "a", sessionID: "s1", viewID: "v1", sessionForced: true))

        XCTAssertFalse(scheduler.isRunning)
    }

    func test_theDrawIsLockedForTheSession() {
        var onError = false
        recordingCoordinator = RecordingCoordinator(
            scheduler: scheduler,
            textAndInputPrivacy: .maskAll,
            imagePrivacy: .maskAll,
            touchPrivacy: .hide,
            rumContextObserver: rumContextObserver,
            srContextPublisher: contextPublisher,
            recorder: recordingMock,
            sampler: .mockRejectAll(),
            telemetry: NOPTelemetry(),
            startRecordingImmediately: true,
            sessionReplayOnError: { onError }
        )
        rumContextObserver.notify(rumContext: RUMCoreContext(applicationID: "a", sessionID: "s1", viewID: "v1"))

        onError = true
        rumContextObserver.notify(rumContext: RUMCoreContext(applicationID: "a", sessionID: "s1", viewID: "v2"))
        XCTAssertFalse(scheduler.isRunning, "a switch turned on mid-session applies to the next session")

        rumContextObserver.notify(rumContext: RUMCoreContext(applicationID: "a", sessionID: "s2", viewID: "v3"))
        XCTAssertTrue(scheduler.isRunning)
    }

    private func prepareRecordingCoordinator(
        sampler: Sampler = .mockKeepAll(),
        textAndInputPrivacy: TextAndInputPrivacyLevel = .maskSensitiveInputs,
        imagePrivacy: ImagePrivacyLevel = .maskNonBundledOnly,
        touchPrivacy: TouchPrivacyLevel = .show,
        telemetry: Telemetry = NOPTelemetry(),
        methodCallTelemetrySamplingRate: Float = 0,
        startRecordingImmediately: Bool = true,
        sessionReplayOnError: Bool = false
    ) {
        recordingCoordinator = RecordingCoordinator(
            scheduler: scheduler,
            textAndInputPrivacy: textAndInputPrivacy,
            imagePrivacy: imagePrivacy,
            touchPrivacy: touchPrivacy,
            rumContextObserver: rumContextObserver,
            srContextPublisher: contextPublisher,
            recorder: recordingMock,
            sampler: sampler,
            telemetry: telemetry,
            startRecordingImmediately: startRecordingImmediately,
            sessionReplayOnError: { sessionReplayOnError },
            methodCallTelemetrySamplingRate: methodCallTelemetrySamplingRate
        )
    }
}

final class RecordingMock: Recording {
   // MARK: - captureNextRecord

    var captureNextRecordCallsCount = 0
    var captureNextRecordCalled: Bool {
        captureNextRecordCallsCount > 0
    }
    var captureNextRecordReceivedRecorderContext: Recorder.Context?
    var captureNextRecordReceivedInvocations: [Recorder.Context] = []
    var captureNextRecordClosure: ((Recorder.Context) throws -> Void)?

    func captureNextRecord(_ recorderContext: Recorder.Context) throws {
        captureNextRecordCallsCount += 1
        captureNextRecordReceivedRecorderContext = recorderContext
        captureNextRecordReceivedInvocations.append(recorderContext)
        try captureNextRecordClosure?(recorderContext)
    }

    var discardWithheldRecordsCallsCount = 0

    func discardWithheldRecords() {
        discardWithheldRecordsCallsCount += 1
    }
}
#endif
