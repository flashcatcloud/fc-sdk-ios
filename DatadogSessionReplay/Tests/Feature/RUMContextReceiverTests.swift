/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

#if os(iOS)
import XCTest
import TestUtilities
import DatadogInternal

@testable import DatadogSessionReplay

class RUMContextReceiverTests: XCTestCase {
    private let receiver = RUMContextReceiver()

    func testWhenMessageContainsNonEmptyRUMBaggage_itNotifiesRUMContext() throws {
        // Given
        let core = PassthroughCoreMock()
        let coreContext: DatadogContext = .mockWith(
            additionalContext: [
                RUMCoreContext(
                    applicationID: "app-id",
                    sessionID: "session-id",
                    viewID: "view-id",
                    viewServerTimeOffset: 123
                )
            ]
        )

        var rumContext: RUMCoreContext?
        receiver.observe(on: NoQueue()) { context, _ in
            rumContext = context
        }

        // When
        XCTAssert(
            receiver.receive(message: .context(coreContext), from: core)
        )

        // Then
        XCTAssertEqual(rumContext?.applicationID, "app-id")
        XCTAssertEqual(rumContext?.sessionID, "session-id")
        XCTAssertEqual(rumContext?.viewID, "view-id")
        XCTAssertEqual(rumContext?.viewServerTimeOffset, 123)
    }

    func testWhenSucceedingMessagesContainDifferentRUMBaggages_itNotifiesRUMContextChange() throws {
        // Given
        let core = PassthroughCoreMock()
        let coreContext1: DatadogContext = .mockWith(
            additionalContext: [
                RUMCoreContext(
                    applicationID: "app-id-1",
                    sessionID: "session-id-1",
                    viewID: "view-id-1",
                    viewServerTimeOffset: 123
                )
            ]
        )

        let coreContext2: DatadogContext = .mockWith(
            additionalContext: [
                RUMCoreContext(
                    applicationID: "app-id-2",
                    sessionID: "session-id-2",
                    viewID: "view-id-2",
                    viewServerTimeOffset: 345
                )
            ]
        )

        var rumContexts: [RUMCoreContext] = []
        receiver.observe(on: NoQueue()) { context, _ in
            context.flatMap { rumContexts.append($0) }
        }
        // When
        XCTAssert(
            receiver.receive(message: .context(coreContext1), from: core)
        )

        XCTAssert(
            receiver.receive(message: .context(coreContext2), from: core)
        )

        // Then
        XCTAssertEqual(rumContexts.count, 2)
        XCTAssertEqual(rumContexts[0].applicationID, "app-id-1")
        XCTAssertEqual(rumContexts[0].sessionID, "session-id-1")
        XCTAssertEqual(rumContexts[0].viewID, "view-id-1")
        XCTAssertEqual(rumContexts[0].viewServerTimeOffset, 123)
        XCTAssertEqual(rumContexts[1].applicationID, "app-id-2")
        XCTAssertEqual(rumContexts[1].sessionID, "session-id-2")
        XCTAssertEqual(rumContexts[1].viewID, "view-id-2")
        XCTAssertEqual(rumContexts[1].viewServerTimeOffset, 345)
    }

    func testWhenSucceedingMessagesContainSameRUMBaggages_itNotifiesRUMContextChangeOnce() throws {
        // Given
        let core = PassthroughCoreMock()
        let coreContext1: DatadogContext = .mockWith(
            additionalContext: [
                RUMCoreContext(
                    applicationID: "app-id",
                    sessionID: "session-id",
                    viewID: "view-id",
                    viewServerTimeOffset: 123
                )
            ]
        )

        let coreContext2: DatadogContext = .mockWith(
            additionalContext: [
                RUMCoreContext(
                    applicationID: "app-id",
                    sessionID: "session-id",
                    viewID: "view-id",
                    viewServerTimeOffset: 123
                )
            ]
        )

        var rumContexts: [RUMCoreContext] = []
        receiver.observe(on: NoQueue()) { context, _ in
            context.flatMap { rumContexts.append($0) }
        }
        // When
        XCTAssert(
            receiver.receive(message: .context(coreContext1), from: core)
        )

        XCTAssert(
            receiver.receive(message: .context(coreContext2), from: core)
        )

        // Then
        XCTAssertEqual(rumContexts.count, 1)
        XCTAssertEqual(rumContexts[0].applicationID, "app-id")
        XCTAssertEqual(rumContexts[0].sessionID, "session-id")
        XCTAssertEqual(rumContexts[0].viewID, "view-id")
        XCTAssertEqual(rumContexts[0].viewServerTimeOffset, 123)
    }

    func testWhenMessageContainsNoRUMBaggage_itResetRUMContext() throws {
        // Given
        let core = PassthroughCoreMock()
        let coreContext1: DatadogContext = .mockWith(
            additionalContext: [
                RUMCoreContext(
                    applicationID: "app-id",
                    sessionID: "session-id",
                    viewID: "view-id",
                    viewServerTimeOffset: 123
                )
            ]
        )

        let coreContext2: DatadogContext = .mockWith()

        var rumContext: RUMCoreContext? = .mockAny()
        receiver.observe(on: NoQueue()) { context, _ in
            rumContext = context
        }

        // When
        XCTAssert(
            receiver.receive(message: .context(coreContext1), from: core)
        )

        XCTAssertEqual(rumContext?.applicationID, "app-id")
        XCTAssertEqual(rumContext?.sessionID, "session-id")
        XCTAssertEqual(rumContext?.viewID, "view-id")
        XCTAssertEqual(rumContext?.viewServerTimeOffset, 123)

        // When
        XCTAssert(
            receiver.receive(message: .context(coreContext2), from: core)
        )
        // Then
        XCTAssertNil(rumContext)
    }

    func testWhenMessageIsNotContext_itReturnsFalse() throws {
        // Given
        let expectation = expectation(description: "observe not called")
        expectation.isInverted = true
        let core = PassthroughCoreMock()

        receiver.observe(on: NoQueue()) { _, _ in
            expectation.fulfill()
        }

        // When
        XCTAssertFalse(
            receiver.receive(message: .payload("value"), from: core)
        )

        // Then
        waitForExpectations(timeout: 0.1)
    }

    // MARK: - FLASHCAT FORK - consent

    func testWhenConsentChanges_itNotifiesWithTheSameRUMContext() {
        let core = PassthroughCoreMock()
        let receiver = RUMContextReceiver()
        let rum = RUMCoreContext(applicationID: "a", sessionID: "s1", viewID: "v1")
        var notified: [(RUMCoreContext?, TrackingConsent)] = []
        receiver.observe(on: NoQueue()) { context, consent in
            notified.append((context, consent))
        }

        XCTAssert(receiver.receive(message: .context(.mockWith(trackingConsent: .pending, additionalContext: [rum])), from: core))
        XCTAssert(receiver.receive(message: .context(.mockWith(trackingConsent: .pending, additionalContext: [rum])), from: core))
        XCTAssert(receiver.receive(message: .context(.mockWith(trackingConsent: .notGranted, additionalContext: [rum])), from: core))

        XCTAssertEqual(notified.map { $0.1 }, [.pending, .notGranted], "a change of consent alone is notified, a repeat is not")
        XCTAssertEqual(notified.map { $0.0 }, [rum, rum])
    }

    func testControl_withoutARUMContext_aConsentChangeIsNotNotified() {
        // There is no replay without a RUM context, so nothing to tell; notifying would only re-run
        // a draw for a session that does not exist.
        let core = PassthroughCoreMock()
        let receiver = RUMContextReceiver()
        var notifications = 0
        receiver.observe(on: NoQueue()) { _, _ in notifications += 1 }

        XCTAssert(receiver.receive(message: .context(.mockWith(trackingConsent: .pending)), from: core))
        XCTAssert(receiver.receive(message: .context(.mockWith(trackingConsent: .granted)), from: core))

        XCTAssertEqual(notifications, 0)
    }
}

#endif
