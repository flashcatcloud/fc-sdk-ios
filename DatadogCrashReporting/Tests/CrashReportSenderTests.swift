/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import XCTest
import TestUtilities
import DatadogInternal

@testable import DatadogCrashReporting

class CrashReportSenderTests: XCTestCase {
    // MARK: - Sending Crash Reports Tests

    func testItSendsCrashReport() {
        // Given
        let receiver = CrashReceiverMock()
        let core = PassthroughCoreMock(messageReceiver: receiver)
        let sender = MessageBusSender(core: core)
        let crashContext: CrashContext = .mockWith(trackingConsent: .granted)
        let crashReport: DDCrashReport = .mockAny()

        // When
        let processed = sender.send(report: crashReport, with: crashContext)

        // Then
        XCTAssertEqual(processed, .processed)
        XCTAssertNotNil(receiver.receivedCrash)
        XCTAssertEqual(receiver.receivedCrash?.report.type, crashReport.type)
        XCTAssertEqual(receiver.receivedCrash?.context.trackingConsent, .granted)
    }

    func testItWaitsUntilTheReceiverHasProcessedTheCrash() {
        // Given
        let receiver = AsyncCrashReceiver(delay: 0.2)
        let core = PassthroughCoreMock(messageReceiver: receiver)
        let sender = MessageBusSender(core: core)

        // When
        let processed = withExtendedLifetime(core) { sender.send(report: .mockAny(), with: .mockAny()) }

        // Then
        XCTAssertEqual(processed, .processed)
        XCTAssertTrue(receiver.hasCompleted, "It must return only once the receiver has processed the crash")
    }

    func testWhenTheReceiverDoesNotCompleteInTime_itReturnsFalse() {
        // Given
        let receiver = AsyncCrashReceiver(delay: 2)
        let core = PassthroughCoreMock(messageReceiver: receiver)
        let sender = MessageBusSender(core: core, processingTimeout: 0.1)

        // When
        let processed = withExtendedLifetime(core) { sender.send(report: .mockAny(), with: .mockAny()) }

        // Then
        XCTAssertEqual(processed, .kept, "The crash report must be kept when its processing is not confirmed")
    }

    func testWhenNoReceiverHandlesTheCrash_itReturnsFalse() {
        // Given
        let core = PassthroughCoreMock(messageReceiver: NOPFeatureMessageReceiver())
        let sender = MessageBusSender(core: core)

        // When
        let processed = withExtendedLifetime(core) { sender.send(report: .mockAny(), with: .mockAny()) }

        // Then
        XCTAssertEqual(processed, .kept, "A crash nothing received must be kept for a launch that enables RUM")
    }

    func testWhenTheReceiverCannotWriteTheCrash_itReturnsFalse() {
        // Given
        let receiver = CrashReceiverMock()
        receiver.outcome = .writeFailed
        let core = PassthroughCoreMock(messageReceiver: receiver)
        let sender = MessageBusSender(core: core)

        // When
        let processed = sender.send(report: .mockAny(), with: .mockAny())

        // Then
        XCTAssertEqual(processed, .writeFailed, "A crash whose events could not be written must be kept")
    }

    func testWhenCoreIsReleased_itReturnsFalse() {
        // Given
        let sender = MessageBusSender(core: nil)

        // When
        let processed = sender.send(report: .mockAny(), with: .mockAny())

        // Then
        XCTAssertEqual(processed, .kept)
    }

    func testItSendsCrashReportWhenTrackingConsentIsPending() {
        // Given
        let receiver = CrashReceiverMock()
        let core = PassthroughCoreMock(messageReceiver: receiver)
        let sender = MessageBusSender(core: core)
        let crashContext: CrashContext = .mockWith(trackingConsent: .pending)
        let crashReport: DDCrashReport = .mockAny()

        // When
        _ = sender.send(report: crashReport, with: crashContext)

        // Then
        XCTAssertEqual(receiver.receivedCrash?.context.trackingConsent, .pending, "RUM writes it under the current consent")
    }

    func testItSendsCrashReportWithCorrectContext() {
        // Given
        let receiver = CrashReceiverMock()
        let core = PassthroughCoreMock(messageReceiver: receiver)
        let sender = MessageBusSender(core: core)
        let crashContext: CrashContext = .mockWith(
            service: "test-service",
            env: "test-env",
            version: "1.0.0",
            trackingConsent: .granted
        )
        let crashReport: DDCrashReport = .mockAny()

        // When
        _ = sender.send(report: crashReport, with: crashContext)

        // Then
        XCTAssertNotNil(receiver.receivedCrash)
        XCTAssertEqual(receiver.receivedCrash?.context.service, "test-service")
        XCTAssertEqual(receiver.receivedCrash?.context.env, "test-env")
        XCTAssertEqual(receiver.receivedCrash?.context.version, "1.0.0")
    }

    // MARK: - Sending Launch Reports Tests

    func testItSendsLaunchReport() {
        // Given
        let core = PassthroughCoreMock()
        let sender = MessageBusSender(core: core)
        let didCrash: Bool = .random()
        let launchReport: LaunchReport = .init(didCrash: didCrash)

        // When
        sender.send(launch: launchReport)

        // Then
        let receivedLaunchReport = core.context.additionalContext(ofType: LaunchReport.self)
        XCTAssertNotNil(receivedLaunchReport)
        XCTAssertEqual(receivedLaunchReport?.didCrash, didCrash)
    }
}

/// Handles crashes and reports them processed after `delay`, from another thread.
private final class AsyncCrashReceiver: FeatureMessageReceiver {
    let delay: TimeInterval
    @ReadWriteLock
    var hasCompleted = false

    init(delay: TimeInterval) {
        self.delay = delay
    }

    func receive(message: FeatureMessage, from core: DatadogCoreProtocol) -> Bool {
        guard case let .payload(crash as Crash) = message else {
            return false
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            self.hasCompleted = true
            crash.completion(.processed)
        }
        return true
    }
}
