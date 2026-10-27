/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import XCTest
import TestUtilities
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
    @ReadWriteLock
    var injectedContext: Data? = nil
    /// Custom backtrace reporter injected to the plugin.
    var injectedBacktraceReporter: BacktraceReporting?

    init(pendingCrashReport: DDCrashReport? = nil) {
        self.pendingCrashReport = pendingCrashReport
    }

    func readPendingCrashReports(completion: ([DDCrashReport]) -> Bool) { _ = completion(pendingCrashReport.map { [$0] } ?? []) }
    func inject(context: Data) { injectedContext = context }
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
        CrashReporting.enable(with: CrashReporterMock(pendingCrashReport: crashReport), in: core)

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
        CrashReporting.enable(with: CrashReporterMock(pendingCrashReport: .mockRandomWith(context: crashContext)), in: core)

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
}
