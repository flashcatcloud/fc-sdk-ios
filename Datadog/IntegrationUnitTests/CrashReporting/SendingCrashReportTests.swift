/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import XCTest
@testable import TestUtilities
@testable import DatadogCore
@testable import DatadogCrashReporting
import DatadogInternal
@testable import DatadogLogs
@testable import DatadogRUM

/// A crash reporter mock with two capabilities:
/// - notifying a pending crash report found at SDK init,
/// - recording crash context data injected from SDK core and features like RUM.
private class CrashReporterMock: CrashReportingPlugin {
    @ReadWriteLock
    var pendingCrashReport: DDCrashReport?
    /// Every crash context injected, in order.
    @ReadWriteLock
    var injectedContexts: [Data] = []
    var injectedContext: Data? { injectedContexts.last }
    /// Custom backtrace reporter injected to the plugin.
    var injectedBacktraceReporter: BacktraceReporting?
    /// Called when the pending crash report is deleted, once processed.
    var onDelete: (() -> Void)?

    init(pendingCrashReport: DDCrashReport? = nil) {
        self.pendingCrashReport = pendingCrashReport
    }

    var crashedLastLaunch: Bool { pendingCrashReport != nil }
    func readPendingCrashReports(process: (DDCrashReport) -> CrashReportOutcome) {
        if let report = pendingCrashReport, process(report) == .processed {
            pendingCrashReport = nil
            onDelete?()
        }
    }
    func inject(context: Data) { _injectedContexts.mutate { $0.append(context) } }
    var backtraceReporter: BacktraceReporting? { injectedBacktraceReporter }
}

/// Covers broad scenarios of sending Crash Reports.
class SendingCrashReportTests: XCTestCase {
    private var core: DatadogCoreProxy! // swiftlint:disable:this implicitly_unwrapped_optional

    override func setUp() {
        super.setUp()
        core = DatadogCoreProxy(context: .mockWith(trackingConsent: .granted))
    }

    override func tearDownWithError() throws {
        try core.flushAndTearDown()
        core = nil
        super.tearDown()
    }

    func testWhenSDKStartsWithPendingCrashReport_itSendsItAsRUMEvent() throws {
        // Given
        let crashContext: CrashContext = .mockWith(
            trackingConsent: .granted, // CR from the app session that has enabled data collection
            lastIsAppInForeground: true, // CR occurred while the app was in the foreground
            lastRUMAttributes: .mockRandom(),
            lastLogAttributes: .mockRandom()
        )
        let crashReport: DDCrashReport = .mockRandomWith(context: crashContext)
        let crashReportAttributes: [String: Encodable] = try XCTUnwrap(crashReport.additionalAttributes.dd.decode())

        // When
        RUM.enable(with: .init(applicationID: "rum-app-id"), in: core)
        try CrashReporting.enableOrThrow(with: CrashReporterMock(pendingCrashReport: crashReport), in: core, processingDelay: 0)

        // Then (RUMError is sent)
        let rumEvent = try XCTUnwrap(core.waitAndReturnEvents(ofFeature: RUMFeature.name, ofType: RUMErrorEvent.self).first)
        XCTAssertEqual(rumEvent.error.message, crashReport.message)
        XCTAssertEqual(rumEvent.error.type, crashReport.type)
        XCTAssertEqual(rumEvent.error.stack, crashReport.stack)
        XCTAssertNotNil(rumEvent.error.threads)
        XCTAssertNotNil(rumEvent.error.binaryImages)
        XCTAssertNotNil(rumEvent.error.meta)
        XCTAssertNotNil(rumEvent.error.wasTruncated)
        let contextAttributes = try XCTUnwrap(rumEvent.context?.contextInfo)
        let lastRUMAttributes = try XCTUnwrap(crashContext.lastRUMAttributes?.contextInfo)
        DDAssertJSONEqual(contextAttributes, lastRUMAttributes.merging(crashReportAttributes) { $1 })
    }

    // MARK: - Crashes With No Active View

    /// Runs the process that crashes - RUM with default configuration (Background Events Tracking disabled) - and
    /// returns the crash context it leaves for the next process, once that context has reached the state the
    /// scenario leads to (it is updated asynchronously). Crash Reporting is enabled first, so the crash context
    /// receives the state of the RUM session from its start.
    private func crashContextOfAProcessThatCrashes(
        when scenario: (RUMMonitorProtocol) -> Void,
        until isReached: (CrashContext) -> Bool
    ) throws -> CrashContext {
        let plugin = CrashReporterMock()
        CrashReporting.enable(with: plugin, in: core)
        RUM.enable(with: .init(applicationID: "rum-app-id"), in: core)

        scenario(RUMMonitor.shared(in: core))

        var crashContext: CrashContext?
        let deadline = Date().addingTimeInterval(5)
        repeat {
            core.flush()
            crashContext = try plugin.injectedContext.map { try CrashReportingFeature.crashContextDecoder.decode(CrashContext.self, from: $0) }
        } while !(crashContext.map(isReached) ?? false) && Date() < deadline
        try core.flushAndTearDown()

        let reached = try XCTUnwrap(crashContext)
        XCTAssertTrue(isReached(reached), "The crash context never reached the state of the scenario")
        return reached
    }

    /// Starts the next process with the crash report found and returns the crash as RUM sends it.
    private func crashSentByTheNextProcess(with crashContext: CrashContext) throws -> RUMErrorEvent? {
        core = DatadogCoreProxy(context: .mockWith(trackingConsent: .granted))
        RUM.enable(with: .init(applicationID: "rum-app-id"), in: core)
        try CrashReporting.enableOrThrow(with: CrashReporterMock(pendingCrashReport: .mockRandomWith(context: crashContext)), in: core, processingDelay: 0)

        return core.waitAndReturnEvents(ofFeature: RUMFeature.name, ofType: RUMErrorEvent.self)
            .first { $0.error.isCrash == true }
    }

    func testWhenAppCrashesInForegroundAfterTheLastTrackedViewStopped_itSendsTheCrashLinkedToThatView() throws {
        // Given (an untracked screen is presented on top of the last tracked view, so that view stops)
        let crashContext = try crashContextOfAProcessThatCrashes(
            when: { monitor in
                monitor.startView(key: "home", name: "Home")
                monitor.stopView(key: "home")
            },
            until: { $0.lastRUMSessionState != nil && $0.lastRUMViewEvent?.view.name == "Home" && $0.lastRUMViewEvent?.view.isActive == false }
        )

        // When
        let crash = try crashSentByTheNextProcess(with: crashContext)

        // Then
        XCTAssertNotNil(crash, "The crash must be sent")
        XCTAssertEqual(crash?.view.name, "Home", "It must be linked to the last screen the user saw")
        XCTAssertEqual(crash?.session.id, crashContext.lastRUMViewEvent?.session.id)
    }

    func testWhenAppCrashesInBackgroundAfterTheLastTrackedViewStopped_itSendsTheCrashInBackgroundView() throws {
        // Given (the app goes to background, which stops the view; Background Events Tracking is disabled)
        let crashContext = try crashContextOfAProcessThatCrashes(
            when: { monitor in
                monitor.startView(key: "home", name: "Home")
                monitor.stopView(key: "home")
                core.context.applicationStateHistory = .mockAppInBackground()
            },
            until: { $0.lastRUMSessionState != nil && $0.lastRUMViewEvent?.view.isActive == false && !$0.lastIsAppInForeground }
        )

        // When
        let crash = try crashSentByTheNextProcess(with: crashContext)

        // Then
        XCTAssertNotNil(crash, "The crash must be sent although Background Events Tracking is disabled")
        XCTAssertEqual(crash?.view.name, RUMOffViewEventsHandlingRule.Constants.backgroundViewName)
        XCTAssertEqual(crash?.session.id, crashContext.lastRUMSessionState.map { RUMUUID(rawValue: $0.sessionUUID).toRUMDataFormat })
    }

    func testControl_whenAppCrashesInForegroundOnAnActiveView_itSendsTheCrashLinkedToThatView() throws {
        // Given
        let crashContext = try crashContextOfAProcessThatCrashes(
            when: { monitor in monitor.startView(key: "home", name: "Home") },
            until: { $0.lastRUMSessionState != nil && $0.lastRUMViewEvent?.view.name == "Home" }
        )

        // When
        let crash = try crashSentByTheNextProcess(with: crashContext)

        // Then
        XCTAssertEqual(crash?.view.name, "Home")
    }

    func testWhenCrashReportingIsEnabled_itWritesTheCrashContextBeforeReturning() throws {
        // Given
        let plugin = CrashReporterMock()

        // When
        CrashReporting.enable(with: plugin, in: core)

        // Then (no waiting: a crash right after `enable()` must already find a crash context)
        let crashContextData = try XCTUnwrap(plugin.injectedContext, "The crash context must be written before `enable()` returns")
        let crashContext = try CrashReportingFeature.crashContextDecoder.decode(CrashContext.self, from: crashContextData)
        let coreContext = try XCTUnwrap(core.currentContext())
        XCTAssertEqual(crashContext.service, coreContext.service)
        XCTAssertEqual(crashContext.trackingConsent, coreContext.trackingConsent)
        XCTAssertNil(crashContext.lastRUMViewEvent)
    }

    func testWhenCrashReportingIsEnabledTwice_theSecondCallDoesNotWriteACrashContext() throws {
        // Given
        CrashReporting.enable(with: CrashReporterMock(), in: core)
        let secondPlugin = CrashReporterMock()

        // When
        CrashReporting.enable(with: secondPlugin, in: core)

        // Then (the second call fails to register and must not replace the live crash context)
        XCTAssertNil(secondPlugin.injectedContext)
    }

    // MARK: - RUM State In The Crash Context

    func testWhenCrashReportingIsEnabledAfterRUM_theCrashContextHasRUMSessionStateAndView() throws {
        // Given
        let plugin = CrashReporterMock()
        RUM.enable(with: .init(applicationID: "rum-app-id"), in: core)
        RUMMonitor.shared(in: core).startView(key: "view", name: "FirstView")
        core.flush()

        // When
        CrashReporting.enable(with: plugin, in: core)
        flushCrashContext()

        // Then
        let crashContext = try decode(XCTUnwrap(plugin.injectedContext))
        let sessionState = try XCTUnwrap(crashContext.lastRUMSessionState, "The session state must reach a crash reporter enabled after RUM")
        XCTAssertNotEqual(sessionState.sessionUUID, .dd.nullUUID)
        XCTAssertEqual(crashContext.lastRUMViewEvent?.view.name, "FirstView")
        XCTAssertEqual(crashContext.lastRUMViewEvent?.session.id, sessionState.sessionUUID.uuidString.lowercased())
    }

    func testWhenCrashReportingIsEnabledAfterRUM_theCrashContextFollowsLaterRUMChanges() throws {
        // Given
        let plugin = CrashReporterMock()
        RUM.enable(with: .init(applicationID: "rum-app-id"), in: core)
        let monitor = RUMMonitor.shared(in: core)
        monitor.startView(key: "view1", name: "FirstView")
        core.flush()
        CrashReporting.enable(with: plugin, in: core)

        // When
        monitor.startView(key: "view2", name: "SecondView")
        monitor.addAttribute(forKey: "global-attribute", value: "value")
        flushCrashContext()

        // Then
        let crashContext = try decode(XCTUnwrap(plugin.injectedContext))
        XCTAssertNotNil(crashContext.lastRUMSessionState)
        XCTAssertEqual(crashContext.lastRUMViewEvent?.view.name, "SecondView")
        XCTAssertEqual((crashContext.lastRUMAttributes?.contextInfo["global-attribute"] as? AnyCodable)?.value as? String, "value")
    }

    func testWhenCrashReportingIsEnabledBeforeRUM_theCrashContextHasRUMSessionStateAndView() throws {
        // Given
        let plugin = CrashReporterMock()
        CrashReporting.enable(with: plugin, in: core)

        // When
        RUM.enable(with: .init(applicationID: "rum-app-id"), in: core)
        RUMMonitor.shared(in: core).startView(key: "view", name: "FirstView")
        flushCrashContext()

        // Then
        let crashContext = try decode(XCTUnwrap(plugin.injectedContext))
        let sessionState = try XCTUnwrap(crashContext.lastRUMSessionState)
        XCTAssertNotEqual(sessionState.sessionUUID, .dd.nullUUID)
        XCTAssertEqual(crashContext.lastRUMViewEvent?.view.name, "FirstView")
    }

    func testWhenCrashReportingIsEnabledAfterRUM_theCrashContextWrittenBeforeReturningHasRUMSessionStateAndView() throws {
        // Given
        let plugin = CrashReporterMock()
        RUM.enable(with: .init(applicationID: "rum-app-id"), in: core)
        RUMMonitor.shared(in: core).startView(key: "view", name: "FirstView")
        core.flush()

        // When
        CrashReporting.enable(with: plugin, in: core)

        // Then (no waiting: the first crash context written is the one written before `enable()` returns)
        let crashContext = try decode(XCTUnwrap(plugin.injectedContexts.first))
        XCTAssertNotNil(crashContext.lastRUMSessionState, "The crash context written at `enable()` must have the session state")
        XCTAssertEqual(crashContext.lastRUMViewEvent?.view.name, "FirstView")
    }

    func testWhenCrashReportingIsEnabledAfterRUMWithSampledOutSession_theCrashContextHasTheRejectedSessionState() throws {
        // Given
        let plugin = CrashReporterMock()
        RUM.enable(with: .init(applicationID: "rum-app-id", sessionSampleRate: 0), in: core)
        RUMMonitor.shared(in: core).startView(key: "view", name: "FirstView")
        core.flush()

        // When
        CrashReporting.enable(with: plugin, in: core)
        flushCrashContext()

        // Then (a crash in a session rejected by the sampler must be dropped, not sampled again in a new session)
        let crashContext = try decode(XCTUnwrap(plugin.injectedContext))
        let sessionState = try XCTUnwrap(crashContext.lastRUMSessionState)
        XCTAssertEqual(sessionState.sessionUUID, .dd.nullUUID)
        XCTAssertNil(crashContext.lastRUMViewEvent)
    }

    func testWhenRUMIsNotEnabled_theCrashContextHasNoRUMState() throws {
        // Given
        let plugin = CrashReporterMock()

        // When
        CrashReporting.enable(with: plugin, in: core)
        flushCrashContext()

        // Then
        let crashContext = try decode(XCTUnwrap(plugin.injectedContext))
        XCTAssertNil(crashContext.lastRUMSessionState)
        XCTAssertNil(crashContext.lastRUMViewEvent)
        XCTAssertNil(crashContext.lastRUMAttributes)
    }

    /// Awaits the crash context reaching the plugin: it goes through the crash context provider's queue, which
    /// `core.flush()` does not await.
    private func flushCrashContext() {
        core.flush()
        (core.get(feature: CrashReportingFeature.self)?.messageReceiver as? Flushable)?.flush()
        core.flush()
    }

    private func decode(_ data: Data) throws -> CrashContext {
        try CrashReportingFeature.crashContextDecoder.decode(CrashContext.self, from: data)
    }

    func testWhenPendingCrashReportHasNoReadableContext_itIsStillSentAsRUMCrash() throws {
        // Given (a crash recorded before any crash context reached the crash reporter)
        let crashReport: DDCrashReport = .mockWith(context: "{}".data(using: .utf8)!)

        // When
        RUM.enable(with: .init(applicationID: "rum-app-id"), in: core)
        try CrashReporting.enableOrThrow(with: CrashReporterMock(pendingCrashReport: crashReport), in: core, processingDelay: 0)

        // Then
        let crash = try XCTUnwrap(
            core.waitAndReturnEvents(ofFeature: RUMFeature.name, ofType: RUMErrorEvent.self).first { $0.error.isCrash == true },
            "A crash must not be dropped for its context"
        )
        XCTAssertEqual(crash.error.type, crashReport.type)
    }

    func testWhenPendingCrashReportIsSent_itIsDeletedOnlyOnceTheRUMErrorIsOnDisk() throws {
        // Given
        let crashReport: DDCrashReport = .mockRandomWith(
            context: CrashContext.mockWith(trackingConsent: .granted, lastIsAppInForeground: true)
        )
        let plugin = CrashReporterMock(pendingCrashReport: crashReport)
        var crashWasOnDiskWhenDeleted: Bool?
        let deleted = expectation(description: "crash report deleted")
        plugin.onDelete = {
            crashWasOnDiskWhenDeleted = self.storedFilesContain(crashReport.message)
            deleted.fulfill()
        }

        // When
        RUM.enable(with: .init(applicationID: "rum-app-id"), in: core)
        try CrashReporting.enableOrThrow(with: plugin, in: core, processingDelay: 0)

        // Then
        wait(for: [deleted], timeout: 30)
        XCTAssertEqual(crashWasOnDiskWhenDeleted, true, "A crash in between would otherwise lose the report")
    }

    func testWhenCrashReportingIsEnabled_itSendsTheLaunchReportBeforeReadingCrashReports() throws {
        // Given
        let plugin = CrashReporterMock(pendingCrashReport: .mockRandomWith(context: CrashContext.mockWith(trackingConsent: .granted)))

        // When
        RUM.enable(with: .init(applicationID: "rum-app-id"), in: core)
        CrashReporting.enable(with: plugin, in: core) // default processing delay
        core.get(feature: CrashReportingFeature.self)?.flush()

        // Then (read before `core.flush()`, which resets the launch report; `currentContext()` gives up after 100 ms)
        var launchReport: LaunchReport?
        for _ in 0..<50 where launchReport == nil {
            launchReport = core.currentContext()?.additionalContext(ofType: LaunchReport.self)
        }
        XCTAssertEqual(launchReport?.didCrash, true)
        XCTAssertNotNil(plugin.pendingCrashReport, "Crash reports must not be read right after enable")
        XCTAssertTrue(core.waitAndReturnEvents(ofFeature: RUMFeature.name, ofType: RUMErrorEvent.self).isEmpty)
    }

    /// Whether a file written by the core contains `string`.
    private func storedFilesContain(_ string: String) -> Bool {
        let files = FileManager.default.enumerator(at: temporaryCoreDirectory.coreDirectory.url, includingPropertiesForKeys: nil)
        return (files?.allObjects as? [URL] ?? []).contains { url in
            (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self).contains(string) } ?? false
        }
    }
}
