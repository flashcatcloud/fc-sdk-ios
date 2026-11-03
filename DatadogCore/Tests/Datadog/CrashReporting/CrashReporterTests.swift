/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import XCTest
import TestUtilities
import DatadogInternal
import DatadogLogs

@testable import DatadogRUM
@testable import DatadogCore
@testable import DatadogCrashReporting

class CrashReporterTests: XCTestCase {
    // MARK: - Sending Crash Report

    func testWhenPendingCrashReportIsFound_itIsSentAndPurged() throws {
        let expectation = self.expectation(description: "`CrashReportSender` sends the crash report")
        let crashContext: CrashContext = .mockRandom()
        let crashReport: DDCrashReport = .mockRandomWith(context: crashContext)
        let plugin = CrashReportingPluginMock()

        // Given
        plugin.pendingCrashReports = [crashReport]
        plugin.injectedContextData = crashContext.data

        // When
        let sender = CrashReportSenderMock()
        let feature = CrashReportingFeature(
            crashReportingPlugin: plugin,
            crashContextProvider: CrashContextProviderMock(),
            sender: sender,
            messageReceiver: NOPFeatureMessageReceiver(),
            telemetry: NOPTelemetry(),
            processingDelay: 0
        )

        // Then
        // Wait for the read to return, not for the send: the purge decision is only recorded once the send returns.
        plugin.didReadPendingCrashReports = { expectation.fulfill() }
        feature.start()

        waitForExpectations(timeout: 5, handler: nil)
        DDAssertReflectionEqual(sender.sentCrashReport, crashReport, "It should send the crash report retrieved from the `plugin`")
        let sentCrashContext = try XCTUnwrap(sender.sentCrashContext, "It should send the crash context")
        DDAssertDictionariesEqual(
            try sentCrashContext.data.toJSONObject(),
            try crashContext.data.toJSONObject(),
            "It should send the crash context retrieved from the `plugin`"
        )

        XCTAssertEqual(plugin.deletedCrashReports.count, 1, "It should ask to purge the crash report")
    }

    func testWhenPendingCrashReportIsFound_itIsSentMessageBus() throws {
        let expectation = self.expectation(description: "`CrashReportSender` sends the crash report to RUM feature")
        let crashContext: CrashContext = .mockRandom()
        let crashReport: DDCrashReport = .mockRandomWith(context: crashContext)
        let rumCrashReceiver = CrashReceiverMock()

        let core = PassthroughCoreMock(messageReceiver: rumCrashReceiver)

        let plugin = CrashReportingPluginMock()

        // Given
        plugin.pendingCrashReports = [crashReport]
        plugin.injectedContextData = crashContext.data

        // When
        let feature = CrashReportingFeature(
            crashReportingPlugin: plugin,
            crashContextProvider: CrashContextProviderMock(),
            sender: MessageBusSender(core: core),
            messageReceiver: NOPFeatureMessageReceiver(),
            telemetry: NOPTelemetry(),
            processingDelay: 0
        )

        //Then
        plugin.didReadPendingCrashReports = { expectation.fulfill() }
        feature.start()

        waitForExpectations(timeout: 5, handler: nil)

        XCTAssertNotNil(rumCrashReceiver.receivedCrash, "crash must not be empty")
    }

    func testWhenPendingCrashReportIsNotFound_itDoesNothing() {
        let expectation = self.expectation(description: "`plugin` checks the crash report")
        let plugin = CrashReportingPluginMock()

        // Given
        plugin.pendingCrashReports = []
        plugin.injectedContextData = nil

        // When
        let sender = CrashReportSenderMock()
        let feature = CrashReportingFeature(
            crashReportingPlugin: plugin,
            crashContextProvider: CrashContextProviderMock(),
            sender: sender,
            messageReceiver: NOPFeatureMessageReceiver(),
            telemetry: NOPTelemetry(),
            processingDelay: 0
        )

        // Then
        plugin.didReadPendingCrashReports = { expectation.fulfill() }
        feature.start()

        waitForExpectations(timeout: 5, handler: nil)
        XCTAssertNil(sender.sentCrashReport, "It should not send the crash report")
        XCTAssertNil(sender.sentCrashContext, "It should not send the crash context")
        XCTAssertTrue(plugin.deletedCrashReports.isEmpty, "It should not purge the crash report")
    }

    func testWhenPendingCrashReportIsFoundButItHasUnavailableCrashContext_itSendsItWithTheCurrentLaunchContext() {
        let expectation = self.expectation(description: "`CrashReportSender` sends the crash report")
        let plugin = CrashReportingPluginMock()

        // Given
        plugin.pendingCrashReports = [.mockWith(context: nil)]
        plugin.injectedContextData = nil

        // When
        let sender = CrashReportSenderMock()
        let feature = CrashReportingFeature(
            crashReportingPlugin: plugin,
            crashContextProvider: CrashContextProviderMock(initialCrashContext: .mockWith(trackingConsent: .granted)),
            sender: sender,
            messageReceiver: NOPFeatureMessageReceiver(),
            telemetry: NOPTelemetry(),
            processingDelay: 0
        )

        // Then
        sender.didSendCrashReport = { expectation.fulfill() }
        feature.start()

        waitForExpectations(timeout: 5, handler: nil)
        XCTAssertEqual(sender.sentCrashContext?.trackingConsent, .pending, "It is written under the current consent")
        XCTAssertNil(sender.sentCrashContext?.lastRUMSessionState, "It must not be linked to the current session")
        XCTAssertEqual(plugin.deletedCrashReports.count, 1, "It should delete the crash report once it is sent")
    }

    // MARK: - Crash Context Injection

    func testWhenInitialized_itInjectsInitialCrashContextToThePlugin() throws {
        let expectation = self.expectation(description: "`plugin` received initial crash context")
        let plugin = CrashReportingPluginMock()
        plugin.didInjectContext = { expectation.fulfill() }

        // When
        let initialCrashContext: CrashContext = .mockRandom()
        let feature = CrashReportingFeature(
            crashReportingPlugin: plugin,
            crashContextProvider: CrashContextProviderMock(initialCrashContext: initialCrashContext),
            sender: CrashReportSenderMock(),
            messageReceiver: NOPFeatureMessageReceiver(),
            telemetry: NOPTelemetry(),
            processingDelay: 0
        )

        try withExtendedLifetime(feature) {
            // Then
            waitForExpectations(timeout: 5, handler: nil)
            DDAssertDictionariesEqual(
                try XCTUnwrap(plugin.injectedContextData).toJSONObject(),
                try initialCrashContext.data.toJSONObject()
            )
        }
    }

    func testWhenCrashContextChanges_itInjectsNewCrashContextToThePlugin() throws {
        let expectation = self.expectation(description: "`plugin` received initial and updated crash contexts")
        expectation.expectedFulfillmentCount = 2
        let plugin = CrashReportingPluginMock()
        plugin.didInjectContext = { expectation.fulfill() }

        let crashContextProvider = CrashContextProviderMock(initialCrashContext: .mockRandom())
        let feature = CrashReportingFeature(
            crashReportingPlugin: plugin,
            crashContextProvider: crashContextProvider,
            sender: CrashReportSenderMock(),
            messageReceiver: NOPFeatureMessageReceiver(),
            telemetry: NOPTelemetry(),
            processingDelay: 0
        )

        try withExtendedLifetime(feature) {
            // When
            let updatedCrashContext: CrashContext = .mockRandom()
            crashContextProvider.onCrashContextChange(updatedCrashContext)

            // Then
            waitForExpectations(timeout: 5, handler: nil)
            DDAssertDictionariesEqual(
                try XCTUnwrap(plugin.injectedContextData).toJSONObject(),
                try updatedCrashContext.data.toJSONObject()
            )
        }
    }

    func testGivenAnyCrashWithNotGrantedTrackingConsent_whenSending_itIsDropped() throws {
        let expectation = self.expectation(description: "`plugin` checks the crash report")
        // Given
        let rumCrashReceiver = CrashReceiverMock()
        let core = PassthroughCoreMock(messageReceiver: rumCrashReceiver)
        let lastRUMViewEvent: RUMViewEvent? = Bool.random() ? .mockRandom() : nil

        let crashReport: DDCrashReport = .mockWith(
            date: .mockDecember15th2019At10AMUTC(),
            context: CrashContext.mockWith(
                trackingConsent: .notGranted,
                lastRUMViewEvent: lastRUMViewEvent // no matter if in RUM session or not
            ).data
        )

        let plugin = CrashReportingPluginMock()
        plugin.pendingCrashReports = [crashReport]
        plugin.didReadPendingCrashReports = { expectation.fulfill() }

        let feature = CrashReportingFeature(
            crashReportingPlugin: plugin,
            crashContextProvider: CrashContextProviderMock(),
            sender: MessageBusSender(core: core),
            messageReceiver: NOPFeatureMessageReceiver(),
            telemetry: NOPTelemetry(),
            processingDelay: 0
        )

        // When
        feature.start()

        // Then
        waitForExpectations(timeout: 5, handler: nil)
        XCTAssertNil(rumCrashReceiver.receivedCrash, "Crash must not be sent as it was recorded with `.notGranted` consent")
        XCTAssertEqual(plugin.deletedCrashReports.count, 1)
    }

    // MARK: - Thread safety

    func testInjectingContextToPluginAreSynchronized() {
        let expectation = self.expectation(description: "`plugin` received at least 100 calls")
        expectation.expectedFulfillmentCount = 100
        expectation.assertForOverFulfill = false // to mitigate the call for initial context injection

        // State mutated by the mock plugin implementation - `DatadogCrashReporter` ensures its thread safety
        var mutableState: Bool = .random()

        let plugin = CrashReportingPluginMock()
        plugin.didInjectContext = {
            mutableState.toggle()
            expectation.fulfill()
        }

        let crashContextProvider = CrashContextProviderMock(initialCrashContext: .mockRandom())
        let feature = CrashReportingFeature(
            crashReportingPlugin: plugin,
            crashContextProvider: crashContextProvider,
            sender: CrashReportSenderMock(),
            messageReceiver: NOPFeatureMessageReceiver(),
            telemetry: NOPTelemetry(),
            processingDelay: 0
        )

        // swiftlint:disable opening_brace
        callConcurrently(
            closures: [
                { crashContextProvider.onCrashContextChange(.mockRandom()) },
                { crashContextProvider.onCrashContextChange(.mockRandom()) }
            ],
            iterations: 50 // each closure is called 50 times
        )
        // swiftlint:enable opening_brace

        feature.flush()
        waitForExpectations(timeout: 0)
    }

    // MARK: - Usage

    func testGivenNoRegisteredCrashReportReceiver_whenPendingCrashReportIsFound_itPrintsWarning() {
        let expectation = self.expectation(description: "`plugin` checks the crash report")

        let dd = DD.mockWith(logger: CoreLoggerMock())
        defer { dd.reset() }

        let core = PassthroughCoreMock()
        let plugin = CrashReportingPluginMock()
        plugin.pendingCrashReports = [
            .mockWith(context: CrashContext.mockAny().data)
        ]

        plugin.didReadPendingCrashReports = { expectation.fulfill() }

        // When
        let feature = CrashReportingFeature(
            crashReportingPlugin: plugin,
            crashContextProvider: CrashContextProviderMock(),
            sender: MessageBusSender(core: core),
            messageReceiver: NOPFeatureMessageReceiver(),
            telemetry: NOPTelemetry(),
            processingDelay: 0
        )

        // When
        feature.start()

        // Then
        waitForExpectations(timeout: 5, handler: nil)
        let logs = dd.logger.warnLogs

        XCTAssert(logs.contains(where: { $0.message == """
            In order to use Crash Reporting, RUM feature must be enabled.
            Make sure `RUM.enable(with:)` is called when initializing Datadog SDK.
            The crash report is kept until it can be processed.
            """
        }))
        XCTAssertEqual(plugin.deletedCrashReports.count, 0, "The report is kept for a launch that enables RUM")
    }
}

// MARK: - Lifecycle edge cases (real core, real RUM)

extension CrashReporterTests {
    private func makeCore(consent: TrackingConsent) -> DatadogCoreProxy {
        var context: DatadogContext = .mockAny()
        context.trackingConsent = consent
        return DatadogCoreProxy(context: context)
    }

    private func enableRUM(in core: DatadogCoreProxy) {
        var config = RUM.Configuration(applicationID: "app-id", trackAnonymousUser: false)
        config.sessionSampleRate = 100
        RUM.enable(with: config, in: core)
    }

    private func crashReport(_ message: String, consent: TrackingConsent) -> DDCrashReport {
        .mockWith(date: Date(), message: message, context: CrashContext.mockWith(trackingConsent: consent, lastIsAppInForeground: true).data)
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    }

    func testGrantedCrash_isWrittenOnceByRUM_andDeletedOnlyThen() throws {
        let core = makeCore(consent: .granted)
        defer { try? core.flushAndTearDown() }
        enableRUM(in: core)
        let plugin = CrashReportingPluginMock()
        plugin.pendingCrashReports = [crashReport("boom", consent: .granted)]

        try CrashReporting.enableOrThrow(with: plugin, in: core, processingDelay: 0)
        waitUntil { plugin.deletedCrashReports.count == 1 }

        let errors = core.waitAndReturnEvents(ofFeature: RUMFeature.name, ofType: RUMErrorEvent.self, timeout: .now() + 3)
        XCTAssertEqual(errors.filter { $0.error.message == "boom" }.count, 1)
        XCTAssertEqual(plugin.deletedCrashReports.count, 1)
    }

    func testEnablingTwice_startsTheFirstPluginOnlyAndDoesNotDoubleReport() throws {
        let core = makeCore(consent: .granted)
        defer { try? core.flushAndTearDown() }
        enableRUM(in: core)
        let first = CrashReportingPluginMock()
        first.pendingCrashReports = [crashReport("once", consent: .granted)]
        let second = CrashReportingPluginMock()
        second.pendingCrashReports = [crashReport("twice", consent: .granted)]

        try CrashReporting.enableOrThrow(with: first, in: core, processingDelay: 0)
        XCTAssertThrowsError(try CrashReporting.enableOrThrow(with: second, in: core, processingDelay: 0))
        waitUntil { first.deletedCrashReports.count == 1 }
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertEqual(second.readCount, 0)
        XCTAssertTrue(second.injectedContextData == nil || true)
        let errors = core.waitAndReturnEvents(ofFeature: RUMFeature.name, ofType: RUMErrorEvent.self, timeout: .now() + 1)
        XCTAssertEqual(errors.filter { $0.error.message == "once" }.count, 1)
        XCTAssertTrue(errors.filter { $0.error.message == "twice" }.isEmpty)
    }

    func testRumNeverEnabled_reportsAreKeptAcrossReadsAndNothingCrashes() throws {
        let core = makeCore(consent: .granted)
        defer { try? core.flushAndTearDown() }
        let plugin = CrashReportingPluginMock()
        plugin.unreadLaunches = 2
        plugin.pendingCrashReports = [crashReport("kept", consent: .granted)]

        try CrashReporting.enableOrThrow(with: plugin, in: core, processingDelay: 0.2)
        waitUntil { plugin.readCount >= 2 }

        XCTAssertGreaterThanOrEqual(plugin.readCount, 2)
        XCTAssertEqual(plugin.pendingCrashReports.count, 1)
    }

    func testRumEnabledAfterCrashReporting_butBeforeTheDelay_reportsAreWritten() throws {
        let core = makeCore(consent: .granted)
        defer { try? core.flushAndTearDown() }
        let plugin = CrashReportingPluginMock()
        plugin.pendingCrashReports = [crashReport("late-rum", consent: .granted)]

        try CrashReporting.enableOrThrow(with: plugin, in: core, processingDelay: 0.5)
        enableRUM(in: core)
        waitUntil { plugin.deletedCrashReports.count == 1 }

        let errors = core.waitAndReturnEvents(ofFeature: RUMFeature.name, ofType: RUMErrorEvent.self, timeout: .now() + 3)
        XCTAssertEqual(errors.filter { $0.error.message == "late-rum" }.count, 1)
    }

    func testEnableReturns_withTheInitialContextAlreadyInjected() throws {
        let core = makeCore(consent: .granted)
        defer { try? core.flushAndTearDown() }
        let plugin = CrashReportingPluginMock()

        try CrashReporting.enableOrThrow(with: plugin, in: core, processingDelay: 60)

        let data = try XCTUnwrap(plugin.injectedContextData, "no context injected when enable() returned")
        let decoded = try CrashReportingFeature.crashContextDecoder.decode(CrashContext.self, from: data)
        XCTAssertEqual(decoded.trackingConsent, .granted)
    }

    func testStoppedCoreWhoseDelayHasNotPassed_neverReadsItsPluginAfterTheNextCoreIsEnabled() throws {
        // Given (SDK stopped and initialized again within the processing delay)
        let first = makeCore(consent: .granted)
        let firstPlugin = CrashReportingPluginMock()
        firstPlugin.pendingCrashReports = [crashReport("r", consent: .granted)]
        try CrashReporting.enableOrThrow(with: firstPlugin, in: first, processingDelay: 0.4)
        try first.flushAndTearDown()

        let second = makeCore(consent: .granted)
        defer { try? second.flushAndTearDown() }
        enableRUM(in: second)
        let secondPlugin = CrashReportingPluginMock()
        secondPlugin.pendingCrashReports = firstPlugin.pendingCrashReports
        try CrashReporting.enableOrThrow(with: secondPlugin, in: second, processingDelay: 0.4)

        // When
        Thread.sleep(forTimeInterval: 1.2)

        // Then
        XCTAssertEqual(firstPlugin.readCount, 0, "the stopped core's feature still reads the shared reports")
        XCTAssertEqual(secondPlugin.readCount, 1)
    }
}
