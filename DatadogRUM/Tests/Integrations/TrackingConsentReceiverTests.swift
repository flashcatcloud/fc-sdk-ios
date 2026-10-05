/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import XCTest
import DatadogInternal
@testable import DatadogRUM
@testable import TestUtilities

class TrackingConsentReceiverTests: XCTestCase {
    private let featureScope = FeatureScopeMock()

    private lazy var monitor = Monitor(
        dependencies: .mockWith(
            featureScope: featureScope,
            sessionSampler: Sampler(samplingRate: 0),
            sessionOnError: true
        ),
        dateProvider: DateProviderMock()
    )

    private lazy var receiver = TrackingConsentReceiver(monitor: monitor)

    private func consent(_ consent: TrackingConsent) -> FeatureMessage {
        .context(.mockWith(trackingConsent: consent))
    }

    func testWhenConsentIsWithdrawn_theSessionKeptOnErrorThrowsAwayWhatItWithheld() throws {
        // No RUM command need arrive between the withdrawal and the next grant, so the session
        // cannot notice it on its own.
        featureScope.contextMock = .mockWith(trackingConsent: .granted)
        monitor.notifySDKInit()
        monitor.startView(key: "home", name: "Home")
        monitor.addAction(type: .custom, name: "tap")
        let session = try XCTUnwrap(monitor.scopes.activeSession)
        XCTAssertTrue(session.context.eventsWithheld)

        XCTAssertFalse(receiver.receive(message: consent(.notGranted), from: NOPDatadogCore()), "context updates are broadcast, not claimed")

        monitor.addError(message: "boom")
        monitor.stopSession() // the mock never fires the scheduled release; ending the session releases

        XCTAssertEqual(featureScope.eventsWritten(ofType: RUMErrorEvent.self).count, 1, "the error reported with consent is released")
        XCTAssertTrue(featureScope.eventsWritten(ofType: RUMActionEvent.self).isEmpty, "what was held before the withdrawal is not")
    }

    func testControl_aConsentThatStaysGranted_throwsNothingAway() throws {
        featureScope.contextMock = .mockWith(trackingConsent: .granted)
        monitor.notifySDKInit()
        monitor.startView(key: "home", name: "Home")
        monitor.addAction(type: .custom, name: "tap")

        _ = receiver.receive(message: consent(.granted), from: NOPDatadogCore())
        _ = receiver.receive(message: consent(.pending), from: NOPDatadogCore())

        monitor.addError(message: "boom")
        monitor.stopSession()

        XCTAssertEqual(featureScope.eventsWritten(ofType: RUMActionEvent.self).count, 1)
    }
}
