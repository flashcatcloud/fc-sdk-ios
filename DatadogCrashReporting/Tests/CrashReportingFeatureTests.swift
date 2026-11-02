/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import XCTest
import TestUtilities
import DatadogInternal

@testable import DatadogCrashReporting

class CrashReportingFeatureTests: XCTestCase {
    // MARK: - Initialization Tests

    func testItInjectsCrashContextOnInitialization() throws {
        // Given
        let plugin = CrashReportingPluginMock()
        let sender = CrashReportSenderMock()
        let initialContext: CrashContext = .mockWith(
            service: "test-service",
            env: "test-env"
        )
        let contextProvider = CrashContextProviderMock(initialCrashContext: initialContext)

        // When
        let feature = CrashReportingFeature.mockWith(
            integration: sender,
            crashReportingPlugin: plugin,
            crashContextProvider: contextProvider
        )

        // Wait for async injection
        feature.flush()

        // Then
        XCTAssertNotNil(plugin.injectedContextData)
        XCTAssertNotNil(contextProvider.onCrashContextChange)
        let decodedContext = try CrashReportingFeature.crashContextDecoder.decode(
            CrashContext.self,
            from: plugin.injectedContextData!
        )
        XCTAssertEqual(decodedContext.service, "test-service")
        XCTAssertEqual(decodedContext.env, "test-env")
    }

    // MARK: - Launch Report Tests

    func testWhenStarted_itSendsTheLaunchReportWithoutReadingCrashReports() {
        // Given
        let plugin = CrashReportingPluginMock()
        plugin.crashedLastLaunch = .mockRandom()
        plugin.pendingCrashReports = [.mockRandomWith(context: .mockWith(trackingConsent: .granted))]
        let sender = CrashReportSenderMock()
        let feature = CrashReportingFeature.mockWith(
            integration: sender,
            crashReportingPlugin: plugin,
            processingDelay: 60
        )

        // When
        feature.start()
        feature.flush()

        // Then
        XCTAssertEqual(sender.sentLaunchReports.map { $0.didCrash }, [plugin.crashedLastLaunch])
        XCTAssertEqual(plugin.readCount, 0, "Crash reports must not be read while the app may still crash at launch")
        XCTAssertTrue(sender.sentCrashReports.isEmpty)
    }

    func testGivenReportsUnreadForTwoLaunches_whenStarted_itReadsThemWithoutWaiting() {
        // Given (e.g. a crash loop: each launch crashed before the processing delay passed)
        let plugin = CrashReportingPluginMock()
        plugin.unreadLaunches = 2
        plugin.pendingCrashReports = [.mockRandomWith(context: .mockWith(trackingConsent: .granted))]
        let sender = CrashReportSenderMock()
        let telemetry = TelemetryMock()
        let feature = CrashReportingFeature.mockWith(
            integration: sender,
            crashReportingPlugin: plugin,
            telemetry: telemetry,
            processingDelay: 60
        )

        // When
        feature.start()
        feature.flush()

        // Then
        XCTAssertEqual(plugin.readCount, 1)
        XCTAssertEqual(sender.sentCrashReports.count, 1)
        XCTAssertEqual(telemetry.messages.firstDebug()?.message, "[CrashReporting] Pending crash reports were not read for 2 launches")
        XCTAssertEqual(plugin.resetUnreadLaunchesCount, 0, "the launch has not outlived the delay yet")
    }

    func testWhenTheProcessingDelayPasses_itResetsTheUnreadLaunchesBeforeReading() {
        // Given (the read keeps the report, e.g. as consent is pending)
        let plugin = CrashReportingPluginMock()
        plugin.pendingCrashReports = [.mockRandomWith(context: .mockWith(trackingConsent: .granted))]
        let sender = CrashReportSenderMock()
        sender.crashReportOutcome = .kept
        var resetsWhenRead: Int?
        let read = expectation(description: "read")
        plugin.didReadPendingCrashReports = {
            resetsWhenRead = plugin.resetUnreadLaunchesCount
            read.fulfill()
        }
        let feature = CrashReportingFeature.mockWith(integration: sender, crashReportingPlugin: plugin, processingDelay: 0.2)

        // When
        feature.start()

        // Then
        wait(for: [read], timeout: 5)
        XCTAssertEqual(resetsWhenRead, 1)
        XCTAssertEqual(plugin.pendingCrashReports.count, 1, "the report is still kept")
    }

    func testGivenReportsUnreadForTwoLaunches_whenTheImmediateReadProcessesNone_theyAreReadAgainAfterTheDelay() {
        // Given (no feature receives crashes yet when the reports are read without waiting)
        let plugin = CrashReportingPluginMock()
        plugin.unreadLaunches = 2
        plugin.pendingCrashReports = [.mockRandomWith(context: .mockWith(trackingConsent: .granted))]
        let sender = CrashReportSenderMock()
        sender.crashReportOutcome = .kept
        let readTwice = expectation(description: "read twice")
        plugin.didReadPendingCrashReports = {
            if plugin.readCount == 2 {
                sender.crashReportOutcome = .processed
                readTwice.fulfill()
            }
        }
        let feature = CrashReportingFeature.mockWith(integration: sender, crashReportingPlugin: plugin, processingDelay: 0.2)

        // When
        feature.start()

        // Then
        wait(for: [readTwice], timeout: 5)
        feature.flush()
        XCTAssertEqual(sender.sentCrashReports.count, 2)
    }

    func testGivenReportsUnreadForOneLaunch_whenStarted_itStillWaits() {
        // Given
        let plugin = CrashReportingPluginMock()
        plugin.unreadLaunches = 1
        plugin.pendingCrashReports = [.mockRandomWith(context: .mockWith(trackingConsent: .granted))]
        let telemetry = TelemetryMock()
        let feature = CrashReportingFeature.mockWith(integration: CrashReportSenderMock(), crashReportingPlugin: plugin, telemetry: telemetry, processingDelay: 60)

        // When
        feature.start()
        feature.flush()

        // Then
        XCTAssertEqual(plugin.readCount, 0)
        XCTAssertTrue(telemetry.messages.isEmpty)
    }

    func testGivenACrashReportKeptFromAnOlderLaunch_whenTheLastLaunchDidNotCrash_itReportsNoCrash() {
        // Given (a crash recorded while consent was pending, kept since: the last launch ended without a crash)
        let plugin = CrashReportingPluginMock()
        plugin.crashedLastLaunch = false
        plugin.pendingCrashReports = [.mockRandomWith(context: .mockWith(trackingConsent: .pending))]
        let sender = CrashReportSenderMock()
        let feature = CrashReportingFeature.mockWith(integration: sender, crashReportingPlugin: plugin)

        // When
        feature.start()
        feature.flush()

        // Then (otherwise RUM would not report the last launch's Watchdog Termination)
        XCTAssertEqual(sender.sentLaunchReports.map { $0.didCrash }, [false])
    }

    func testWhenStarted_itReadsCrashReportsOnceTheProcessingDelayHasPassed() {
        // Given
        let plugin = CrashReportingPluginMock()
        plugin.pendingCrashReports = [.mockRandomWith(context: .mockWith(trackingConsent: .granted))]
        let sender = CrashReportSenderMock()
        let feature = CrashReportingFeature.mockWith(
            integration: sender,
            crashReportingPlugin: plugin,
            processingDelay: 0.2
        )
        let read = expectation(description: "didReadPendingCrashReports")
        plugin.didReadPendingCrashReports = { read.fulfill() }

        // When
        let start = Date()
        feature.start()

        // Then
        waitForExpectations(timeout: 5)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.2)
        XCTAssertEqual(sender.sentCrashReports.count, 1)
        XCTAssertEqual(plugin.deletedCrashReports.count, 1)
    }

    // MARK: - Crash Report Reading Tests

    func testItSendsCrashReportWithValidContext() {
        // Given
        let plugin = CrashReportingPluginMock()
        let crashContext: CrashContext = .mockWith(
            service: "test-service",
            env: "test-env",
            version: "1.0.0"
        )
        let crashReport: DDCrashReport = .mockRandomWith(context: crashContext)
        plugin.pendingCrashReports = [crashReport]

        let sender = CrashReportSenderMock()
        let feature = CrashReportingFeature.mockWith(
            integration: sender,
            crashReportingPlugin: plugin
        )

        // When
        feature.start()
        feature.flush()

        // Then
        XCTAssertNotNil(sender.sentCrashReport)
        XCTAssertEqual(sender.sentCrashContext?.service, "test-service")
        XCTAssertEqual(sender.sentCrashContext?.env, "test-env")
        XCTAssertEqual(sender.sentCrashContext?.version, "1.0.0")
        XCTAssertEqual(plugin.deletedCrashReports.count, 1)
        XCTAssertTrue(plugin.pendingCrashReports.isEmpty)
    }

    func testItSendsEveryPendingCrashReportInOrderWithItsOwnContext() {
        // Given
        let plugin = CrashReportingPluginMock()
        let crashReports: [DDCrashReport] = ["first", "second", "third"].map { service in
            .mockRandomWith(context: .mockWith(service: service, trackingConsent: .granted))
        }
        plugin.pendingCrashReports = crashReports

        let sender = CrashReportSenderMock()
        let feature = CrashReportingFeature.mockWith(
            integration: sender,
            crashReportingPlugin: plugin
        )

        // When
        feature.start()
        feature.flush()

        // Then
        XCTAssertEqual(sender.sentCrashReports.map { $0.report.message }, crashReports.map { $0.message })
        XCTAssertEqual(sender.sentCrashReports.map { $0.context.service }, ["first", "second", "third"])
        XCTAssertEqual(plugin.deletedCrashReports.map { $0.message }, crashReports.map { $0.message })
    }

    func testWhenTheCrashIsNotKnownToBeProcessed_itKeepsTheCrashReport() {
        // Given
        let plugin = CrashReportingPluginMock()
        plugin.pendingCrashReports = [.mockRandomWith(context: .mockWith(trackingConsent: .granted))]
        let sender = CrashReportSenderMock()
        sender.crashReportOutcome = .kept // e.g. RUM did not confirm the write in time

        let feature = CrashReportingFeature.mockWith(
            integration: sender,
            crashReportingPlugin: plugin
        )

        // When
        feature.start()
        feature.flush()

        // Then
        XCTAssertEqual(sender.sentCrashReports.count, 1)
        XCTAssertTrue(plugin.deletedCrashReports.isEmpty, "The report must be kept until its crash is known to be written")
        XCTAssertEqual(plugin.pendingCrashReports.count, 1)
    }

    func testItSendsValidCrashReportsWhenOneHasMalformedContext() {
        // Given
        let plugin = CrashReportingPluginMock()
        let first: DDCrashReport = .mockRandomWith(context: .mockWith(service: "first"))
        let malformed: DDCrashReport = .mockWith(context: "not a valid context".data(using: .utf8)!)
        let last: DDCrashReport = .mockRandomWith(context: .mockWith(service: "last"))
        plugin.pendingCrashReports = [first, malformed, last]

        let sender = CrashReportSenderMock()
        let feature = CrashReportingFeature.mockWith(
            integration: sender,
            crashReportingPlugin: plugin,
            crashContextProvider: CrashContextProviderMock(initialCrashContext: .mockWith(service: "current", trackingConsent: .granted))
        )

        // When
        feature.start()
        feature.flush()

        // Then
        XCTAssertEqual(sender.sentCrashReports.map { $0.context.service }, ["first", "current", "last"], "The malformed one is sent with the current launch's context")
        XCTAssertEqual(plugin.deletedCrashReports.count, 3, "It should delete all reports, including the malformed one")
    }

    func testGivenCrashReportWithMalformedOrMissingContext_itIsSentWithTheCurrentLaunchContext() throws {
        for reportContext in ["not a valid context".data(using: .utf8)!, "{}".data(using: .utf8)!, nil] {
            // Given
            let plugin = CrashReportingPluginMock()
            plugin.pendingCrashReports = [.mockWith(context: reportContext)]
            let current: CrashContext = .mockWith(
                service: "current-service",
                trackingConsent: .granted,
                lastRUMViewEvent: .mockRandom(),
                lastRUMSessionState: .mockRandom(),
                appLaunchDate: .mockRandomInThePast(),
                lastRUMAttributes: .mockRandom()
            )
            let sender = CrashReportSenderMock()
            let feature = CrashReportingFeature.mockWith(
                integration: sender,
                crashReportingPlugin: plugin,
                crashContextProvider: CrashContextProviderMock(initialCrashContext: current)
            )

            // When
            feature.start()
            feature.flush()

            // Then
            let context = try XCTUnwrap(sender.sentCrashContext, "A crash must not be dropped for its context")
            XCTAssertEqual(context.service, "current-service")
            XCTAssertEqual(context.trackingConsent, .pending, "It is written under the current consent, never bypassing it")
            XCTAssertNil(context.lastRUMViewEvent, "It must not be linked to the current process' view")
            XCTAssertNil(context.lastRUMSessionState, "It must not be linked to the current process' session")
            XCTAssertNil(context.lastRUMAttributes)
            XCTAssertNil(context.appLaunchDate)
            XCTAssertEqual(plugin.deletedCrashReports.count, 1)
        }
    }

    func testGivenCrashReportWithMalformedContext_itIsNotAttributedToTheCurrentUserAndTakesTheAppAndOSOfTheReport() throws {
        // Given
        let plugin = CrashReportingPluginMock()
        plugin.pendingCrashReports = [
            .mockWith(
                context: nil,
                system: .init(appVersion: "1.2.3", appBuild: "45", osName: "iOS", osVersion: "17.4.1", osBuild: "21E236")
            )
        ]
        let current: CrashContext = .mockWith(
            version: "2.0.0",
            buildNumber: "60",
            trackingConsent: .granted,
            userInfo: .mockRandom(),
            accountInfo: .mockRandom()
        )
        let sender = CrashReportSenderMock()
        let feature = CrashReportingFeature.mockWith(
            integration: sender,
            crashReportingPlugin: plugin,
            crashContextProvider: CrashContextProviderMock(initialCrashContext: current),
            bundleVersion: "2.0.0"
        )

        // When
        feature.start()
        feature.flush()

        // Then
        let context = try XCTUnwrap(sender.sentCrashContext)
        XCTAssertNil(context.userInfo, "Another user may have signed in since the crash")
        XCTAssertNil(context.accountInfo)
        XCTAssertEqual(context.version, "1.2.3")
        XCTAssertEqual(context.buildNumber, "45")
        XCTAssertEqual(context.os.version, "17.4.1")
        XCTAssertEqual(context.os.versionMajor, "17")
        XCTAssertEqual(context.os.build, "21E236")
        XCTAssertEqual(context.trackingConsent, .pending)
    }

    func testGivenCrashReportWithMalformedContext_whenTheCurrentVersionIsNotTheBundles_itKeepsTheCurrentVersion() throws {
        // Given (a version set by a cross-platform framework or a custom version, which the report does not carry)
        let plugin = CrashReportingPluginMock()
        plugin.pendingCrashReports = [
            .mockWith(
                context: nil,
                system: .init(appVersion: "1.2.3", appBuild: "45", osName: "iOS", osVersion: "17.4.1", osBuild: "21E236")
            )
        ]
        let current: CrashContext = .mockWith(version: "7.1.0-js", buildNumber: "60", trackingConsent: .granted)
        let sender = CrashReportSenderMock()
        let feature = CrashReportingFeature.mockWith(
            integration: sender,
            crashReportingPlugin: plugin,
            crashContextProvider: CrashContextProviderMock(initialCrashContext: current),
            bundleVersion: "2.0.0"
        )

        // When
        feature.start()
        feature.flush()

        // Then
        let context = try XCTUnwrap(sender.sentCrashContext)
        XCTAssertEqual(context.version, "7.1.0-js")
        XCTAssertEqual(context.buildNumber, "60")
        XCTAssertEqual(context.os.version, "17.4.1", "The OS is still the crashed process's")
    }

    func testGivenCrashReportWithMalformedContext_whenThereIsNoCurrentContextYet_itIsKept() {
        // Given
        let plugin = CrashReportingPluginMock()
        plugin.pendingCrashReports = [.mockWith(context: "not a valid context".data(using: .utf8)!)]
        let sender = CrashReportSenderMock()
        let feature = CrashReportingFeature.mockWith(
            integration: sender,
            crashReportingPlugin: plugin,
            crashContextProvider: CrashContextProviderMock(initialCrashContext: nil)
        )

        // When
        feature.start()
        feature.flush()

        // Then
        XCTAssertNil(sender.sentCrashReport)
        XCTAssertTrue(plugin.deletedCrashReports.isEmpty, "It is kept until a context exists to report it with")
    }

    // MARK: - Tracking Consent Tests

    private func startFeature(
        withPendingCrashRecordedWith recordedConsent: TrackingConsent,
        currentConsent: TrackingConsent
    ) -> (CrashReportingFeature, CrashReportingPluginMock, CrashReportSenderMock, CrashContextProviderMock) {
        let plugin = CrashReportingPluginMock()
        plugin.pendingCrashReports = [.mockRandomWith(context: .mockWith(trackingConsent: recordedConsent))]
        let sender = CrashReportSenderMock()
        let contextProvider = CrashContextProviderMock(initialCrashContext: .mockWith(trackingConsent: currentConsent))
        let feature = CrashReportingFeature.mockWith(
            integration: sender,
            crashReportingPlugin: plugin,
            crashContextProvider: contextProvider
        )
        feature.start()
        feature.flush()
        return (feature, plugin, sender, contextProvider)
    }

    func testGivenCrashRecordedWithGrantedConsent_itIsSentWhateverTheCurrentConsent() {
        // When
        let (_, plugin, sender, _) = startFeature(
            withPendingCrashRecordedWith: .granted,
            currentConsent: [.granted, .notGranted, .pending].randomElement()!
        )

        // Then
        XCTAssertEqual(sender.sentCrashReports.count, 1)
        XCTAssertEqual(plugin.deletedCrashReports.count, 1)
    }

    func testGivenCrashRecordedWithNotGrantedConsent_itIsDeletedWithoutSending() {
        // When
        let (_, plugin, sender, _) = startFeature(
            withPendingCrashRecordedWith: .notGranted,
            currentConsent: [.granted, .notGranted, .pending].randomElement()!
        )

        // Then
        XCTAssertTrue(sender.sentCrashReports.isEmpty)
        XCTAssertEqual(plugin.deletedCrashReports.count, 1)
    }

    func testGivenCrashRecordedWithPendingConsent_whileConsentIsStillPending_itIsKeptWithoutSending() {
        // When
        let (_, plugin, sender, _) = startFeature(withPendingCrashRecordedWith: .pending, currentConsent: .pending)

        // Then
        XCTAssertTrue(sender.sentCrashReports.isEmpty, "Nothing may be sent before consent is granted")
        XCTAssertTrue(plugin.deletedCrashReports.isEmpty, "The crash must be kept until consent is resolved")
        XCTAssertEqual(plugin.pendingCrashReports.count, 1)
    }

    func testGivenCrashRecordedWithPendingConsent_whenConsentIsGranted_itIsSentAndDeleted() {
        // Given
        let (feature, plugin, sender, contextProvider) = startFeature(withPendingCrashRecordedWith: .pending, currentConsent: .pending)

        // When
        contextProvider.onCrashContextChange(.mockWith(trackingConsent: .granted))
        feature.flush()

        // Then
        XCTAssertEqual(sender.sentCrashReports.count, 1)
        XCTAssertEqual(sender.sentCrashContext?.trackingConsent, .pending, "RUM writes it under the current consent")
        XCTAssertEqual(plugin.deletedCrashReports.count, 1)
    }

    func testGivenCrashRecordedWithPendingConsent_whenConsentIsDeclined_itIsDeletedWithoutSending() {
        // Given
        let (feature, plugin, sender, contextProvider) = startFeature(withPendingCrashRecordedWith: .pending, currentConsent: .pending)

        // When
        contextProvider.onCrashContextChange(.mockWith(trackingConsent: .notGranted))
        feature.flush()

        // Then
        XCTAssertTrue(sender.sentCrashReports.isEmpty)
        XCTAssertEqual(plugin.deletedCrashReports.count, 1)
    }

    func testGivenCrashRecordedWithPendingConsent_whenConsentIsAlreadyGrantedAtLaunch_itIsSent() {
        // When
        let (_, plugin, sender, _) = startFeature(withPendingCrashRecordedWith: .pending, currentConsent: .granted)

        // Then
        XCTAssertEqual(sender.sentCrashReports.count, 1)
        XCTAssertEqual(plugin.deletedCrashReports.count, 1)
    }

    func testWhenConsentIsGrantedBeforeTheProcessingDelay_itDoesNotReadCrashReportsEarly() {
        // Given
        let plugin = CrashReportingPluginMock()
        plugin.pendingCrashReports = [.mockRandomWith(context: .mockWith(trackingConsent: .pending))]
        let contextProvider = CrashContextProviderMock(initialCrashContext: .mockWith(trackingConsent: .pending))
        let feature = CrashReportingFeature.mockWith(
            integration: CrashReportSenderMock(),
            crashReportingPlugin: plugin,
            crashContextProvider: contextProvider,
            processingDelay: 60
        )
        feature.start()

        // When
        contextProvider.onCrashContextChange(.mockWith(trackingConsent: .granted))
        feature.flush()

        // Then
        XCTAssertEqual(plugin.readCount, 0)
    }

    // MARK: - Crash Context Injection Tests

    func testItInjectsCrashContextWhenContextChanges() {
        // Given
        let plugin = CrashReportingPluginMock()
        let sender = CrashReportSenderMock()
        let contextProvider = CrashContextProviderMock()

        let feature = CrashReportingFeature.mockWith(
            integration: sender,
            crashReportingPlugin: plugin,
            crashContextProvider: contextProvider
        )

        // When
        let newContext: CrashContext = .mockWith(
            service: "new-service",
            env: "new-env"
        )
        contextProvider.onCrashContextChange(newContext)
        feature.flush()

        // Then
        XCTAssertNotNil(plugin.injectedContextData)
        let decodedContext = try? CrashReportingFeature.crashContextDecoder.decode(
            CrashContext.self,
            from: plugin.injectedContextData!
        )
        XCTAssertEqual(decodedContext?.service, "new-service")
        XCTAssertEqual(decodedContext?.env, "new-env")
    }

    // MARK: - Telemetry Tests

    func testItReportsTelemetryOnDecodingError() {
        // Given
        let plugin = CrashReportingPluginMock()
        let malformedData = "not valid JSON".data(using: .utf8)!
        let crashReport: DDCrashReport = .mockWith(context: malformedData)
        plugin.pendingCrashReports = [crashReport]

        let sender = CrashReportSenderMock()
        let telemetry = TelemetryMock()
        let expectation = self.expectation(description: "didReadPendingCrashReports")

        let feature = CrashReportingFeature.mockWith(
            integration: sender,
            crashReportingPlugin: plugin,
            telemetry: telemetry
        )

        plugin.didReadPendingCrashReports = {
            expectation.fulfill()
        }

        // When
        feature.start()

        // Then
        waitForExpectations(timeout: 1.0)
        XCTAssertEqual(telemetry.messages.count, 1)
        XCTAssertTrue(telemetry.messages.firstError()?.message.contains("Failed to decode crash report context") == true)
    }
}

// MARK: - Lifecycle edge cases

extension CrashReportingFeatureTests {
    private func report(_ message: String, consent: TrackingConsent?) -> DDCrashReport {
        .mockWith(message: message, context: consent.map { CrashContext.mockWith(trackingConsent: $0).data })
    }

    func testMixedReportsUnderPendingConsent_thenGranted_areSentOldestFirstAndEverythingResolvedIsDeleted() throws {
        // Given
        let plugin = CrashReportingPluginMock()
        plugin.pendingCrashReports = [
            report("p1", consent: .pending),
            report("g1", consent: .granted),
            report("n1", consent: .notGranted),
            report("m1", consent: nil), // missing context
            report("p2", consent: .pending)
        ]
        let sender = CrashReportSenderMock()
        let provider = CrashContextProviderMock(initialCrashContext: .mockWith(trackingConsent: .pending))
        let feature = CrashReportingFeature.mockWith(integration: sender, crashReportingPlugin: plugin, crashContextProvider: provider)
        feature.start()
        feature.flush()

        // Then (while pending)
        XCTAssertEqual(sender.sentCrashReports.map { $0.report.message }, ["g1"])
        XCTAssertEqual(plugin.pendingCrashReports.map { $0.message }, ["p1", "m1", "p2"])

        // When
        provider.onCrashContextChange(.mockWith(trackingConsent: .granted))
        feature.flush()

        // Then
        XCTAssertEqual(sender.sentCrashReports.map { $0.report.message }, ["g1", "p1", "m1", "p2"])
        XCTAssertTrue(plugin.pendingCrashReports.isEmpty)
    }

    func testFallbackContextCarriesNothingOfTheCurrentProcess() throws {
        // Given
        let current: CrashContext = .mockWith(
            trackingConsent: .granted,
            userInfo: UserInfo(id: "USER-ID-SECRET", name: "USER-NAME-SECRET", email: "user-secret@example.com", extraInfo: ["k": "EXTRA-SECRET"]),
            accountInfo: AccountInfo(id: "ACCOUNT-ID-SECRET", name: "ACCOUNT-NAME-SECRET", extraInfo: ["a": "ACCOUNT-EXTRA-SECRET"]),
            lastRUMViewEvent: .mockRandom(),
            lastRUMSessionState: .mockRandom(),
            lastRUMAttributes: RUMEventAttributes(contextInfo: ["rum-attr": "RUM-ATTR-SECRET"]),
            lastLogAttributes: LogEventAttributes(attributes: ["log-attr": "LOG-ATTR-SECRET"])
        )
        let sessionID = current.lastRUMSessionState!.sessionUUID.uuidString
        let viewID = current.lastRUMViewEvent!.view.id
        let plugin = CrashReportingPluginMock()
        plugin.pendingCrashReports = [report("m", consent: nil), .mockWith(message: "bad", context: Data("{".utf8))]
        let sender = CrashReportSenderMock()
        let feature = CrashReportingFeature.mockWith(integration: sender, crashReportingPlugin: plugin, crashContextProvider: CrashContextProviderMock(initialCrashContext: current))

        // When
        feature.start()
        feature.flush()

        // Then
        XCTAssertEqual(sender.sentCrashReports.count, 2)
        for sent in sender.sentCrashReports {
            let json = String(decoding: try CrashReportingFeature.crashContextEncoder.encode(sent.context), as: UTF8.self)
            for secret in ["USER-ID-SECRET", "USER-NAME-SECRET", "user-secret@example.com", "EXTRA-SECRET", "ACCOUNT-ID-SECRET", "ACCOUNT-NAME-SECRET", "RUM-ATTR-SECRET", "LOG-ATTR-SECRET", sessionID, viewID] {
                XCTAssertFalse(json.contains(secret), "\(secret) leaked into the fallback context")
            }
            XCTAssertNil(sent.context.lastLogAttributes)
        }
    }

    func testFallbackContext_isDeletedWithoutSendingWhenCurrentConsentIsDeclined() {
        let plugin = CrashReportingPluginMock()
        plugin.pendingCrashReports = [report("m", consent: nil)]
        let sender = CrashReportSenderMock()
        let feature = CrashReportingFeature.mockWith(integration: sender, crashReportingPlugin: plugin, crashContextProvider: CrashContextProviderMock(initialCrashContext: .mockWith(trackingConsent: .notGranted)))
        feature.start()
        feature.flush()
        XCTAssertTrue(sender.sentCrashReports.isEmpty)
        XCTAssertTrue(plugin.pendingCrashReports.isEmpty)
    }

    func testEarlyReadBeforeAnyContext_keepsPendingAndUnknownReportsThenSendsThemAtTheDelay() {
        // Given (the core context has not reached the provider when the early read happens)
        let plugin = CrashReportingPluginMock()
        plugin.unreadLaunches = 2
        plugin.pendingCrashReports = [report("g", consent: .granted), report("p", consent: .pending)]
        let sender = CrashReportSenderMock()
        let provider = CrashContextProviderMock(initialCrashContext: nil)
        let feature = CrashReportingFeature.mockWith(integration: sender, crashReportingPlugin: plugin, crashContextProvider: provider, processingDelay: 0.5)

        // When
        feature.start()
        feature.flush()
        XCTAssertEqual(sender.sentCrashReports.map { $0.report.message }, ["g"], "only the report that needs no consent decision")
        provider.onCrashContextChange(.mockWith(trackingConsent: .granted))
        feature.flush()
        XCTAssertEqual(plugin.readCount, 1, "no early second read before the delay")

        // Then
        let deadline = Date().addingTimeInterval(5)
        while plugin.readCount < 2 && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        feature.flush()
        XCTAssertEqual(sender.sentCrashReports.map { $0.report.message }, ["g", "p"])
        XCTAssertTrue(plugin.pendingCrashReports.isEmpty)
    }

    func testConsentFlappingAfterTheDelay_neverSendsAReportTwice() {
        // Given
        let plugin = CrashReportingPluginMock()
        plugin.pendingCrashReports = [report("p", consent: .pending)]
        let sender = CrashReportSenderMock()
        let provider = CrashContextProviderMock(initialCrashContext: .mockWith(trackingConsent: .pending))
        let feature = CrashReportingFeature.mockWith(integration: sender, crashReportingPlugin: plugin, crashContextProvider: provider)
        feature.start()
        feature.flush()

        // When
        for consent: TrackingConsent in [.granted, .pending, .granted, .notGranted, .granted, .granted, .pending] {
            provider.onCrashContextChange(.mockWith(trackingConsent: consent))
        }
        feature.flush()

        // Then
        XCTAssertEqual(sender.sentCrashReports.count, 1)
    }

    func testAReportThatCouldNotBeWritten_isRetriedOnlyWhenConsentIsResolvedAgain() {
        // Given
        let plugin = CrashReportingPluginMock()
        plugin.pendingCrashReports = [report("g", consent: .granted)]
        let sender = CrashReportSenderMock()
        sender.crashReportOutcome = .writeFailed
        let provider = CrashContextProviderMock(initialCrashContext: .mockWith(trackingConsent: .pending))
        let feature = CrashReportingFeature.mockWith(integration: sender, crashReportingPlugin: plugin, crashContextProvider: provider)
        feature.start()
        feature.flush()
        XCTAssertEqual(sender.sentCrashReports.count, 1)

        // When
        provider.onCrashContextChange(.mockWith(trackingConsent: .pending))
        feature.flush()

        // Then
        XCTAssertEqual(sender.sentCrashReports.count, 1)
    }

    func testAFailingReadDoesNotPreventTheNextOneAndTheDelayedReadHappensOnce() {
        let plugin = CrashReportingPluginMock()
        plugin.pendingCrashReports = [report("g", consent: .granted)]
        let sender = CrashReportSenderMock()
        sender.crashReportOutcome = .kept
        let feature = CrashReportingFeature.mockWith(integration: sender, crashReportingPlugin: plugin, processingDelay: 0.1)
        feature.start()
        Thread.sleep(forTimeInterval: 0.6)
        feature.flush()
        XCTAssertEqual(plugin.readCount, 1)
    }

    func testContextWithEmptyJSONObject_andTruncatedJSON_andWrongTypes_areAllHandledAsMalformed() throws {
        let datas: [Data] = [Data("{}".utf8), Data("[]".utf8), Data("null".utf8), Data("{\"trackingConsent\": 42}".utf8), Data(), Data([0xFF, 0x00])]
        for data in datas {
            let plugin = CrashReportingPluginMock()
            plugin.pendingCrashReports = [.mockWith(message: "x", context: data)]
            let sender = CrashReportSenderMock()
            let feature = CrashReportingFeature.mockWith(integration: sender, crashReportingPlugin: plugin, crashContextProvider: CrashContextProviderMock(initialCrashContext: .mockWith(trackingConsent: .granted)))
            feature.start()
            feature.flush()
            XCTAssertEqual(sender.sentCrashReports.count, 1, "context \(String(decoding: data, as: UTF8.self))")
            XCTAssertEqual(sender.sentCrashContext?.trackingConsent, .pending)
        }
    }

    func testAContextRecordedWithoutNewFields_isStillDecoded() throws {
        // A context written by an older SDK (no lastLogAttributes, appLaunchDate, accountInfo, ...) must keep its identity.
        var json = try JSONSerialization.jsonObject(with: CrashContext.mockWith(service: "old-service", trackingConsent: .granted).data) as! [String: Any] // swiftlint:disable:this force_cast
        for key in ["lastLogAttributes", "appLaunchDate", "accountInfo", "lastRUMAttributes", "carrierInfo", "lastRUMSessionState", "lastRUMViewEvent"] { json[key] = nil }
        let plugin = CrashReportingPluginMock()
        plugin.pendingCrashReports = [.mockWith(message: "x", context: try JSONSerialization.data(withJSONObject: json))]
        let sender = CrashReportSenderMock()
        let feature = CrashReportingFeature.mockWith(integration: sender, crashReportingPlugin: plugin, crashContextProvider: CrashContextProviderMock(initialCrashContext: .mockWith(service: "current", trackingConsent: .granted)))
        feature.start()
        feature.flush()
        XCTAssertEqual(sender.sentCrashContext?.service, "old-service")
        XCTAssertEqual(sender.sentCrashContext?.trackingConsent, .granted)
    }

}

private final class LateReceiver: FeatureMessageReceiver {
    let delay: TimeInterval
    @ReadWriteLock
    var received = 0
    init(delay: TimeInterval) { self.delay = delay }
    func receive(message: FeatureMessage, from core: DatadogCoreProtocol) -> Bool {
        guard case let .payload(crash as Crash) = message else { return false }
        received += 1
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { crash.completion(.processed) }
        return true
    }
}
