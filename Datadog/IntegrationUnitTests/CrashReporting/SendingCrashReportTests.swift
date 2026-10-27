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
    @ReadWriteLock
    var injectedContext: Data? = nil
    /// Custom backtrace reporter injected to the plugin.
    var injectedBacktraceReporter: BacktraceReporting?
    /// Called when the pending crash report is deleted, once processed.
    var onDelete: (() -> Void)?

    init(pendingCrashReport: DDCrashReport? = nil) {
        self.pendingCrashReport = pendingCrashReport
    }

    var crashedLastLaunch: Bool { pendingCrashReport != nil }
    func readPendingCrashReports(process: (DDCrashReport) -> Bool) {
        if let report = pendingCrashReport, process(report) {
            pendingCrashReport = nil
            onDelete?()
        }
    }
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
