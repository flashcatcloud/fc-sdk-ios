/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import XCTest
import DatadogInternal
@testable import DatadogRUM
@testable import TestUtilities

/// What the host application is told about a session kept only in case it reports an error.
class RUMSessionOnErrorMonitorTests: XCTestCase {
    private let featureScope = FeatureScopeMock()

    private func monitor(sessionSampleRate: SampleRate, sessionOnError: Bool) -> Monitor {
        featureScope.contextMock = .mockWith(trackingConsent: .granted)
        let monitor = Monitor(
            dependencies: .mockWith(featureScope: featureScope, sessionSampler: Sampler(samplingRate: sessionSampleRate), sessionOnError: sessionOnError),
            dateProvider: DateProviderMock()
        )
        monitor.notifySDKInit()
        return monitor
    }

    private func currentSessionID(of monitor: Monitor) -> String? {
        var id: String?
        monitor.currentSessionID { id = $0 }
        return id
    }

    func testWhileTheSessionIsWithheld_noSessionIDIsReported_andTheRealOneOnceReleased() throws {
        // The backend may never hear of the session: an id handed out before it does would lead
        // nowhere. Once the events are out, the id is the one the backend has.
        let monitor = monitor(sessionSampleRate: 0, sessionOnError: true)
        let session = try XCTUnwrap(monitor.scopes.activeSession)
        XCTAssertTrue(session.context.eventsWithheld)

        XCTAssertNil(currentSessionID(of: monitor))

        monitor.startView(key: "home", name: "Home")
        monitor.addError(message: "boom")
        monitor.setForcedSession() // releases at once; the jitter is not fired by the mock
        XCTAssertFalse(session.context.eventsWithheld)

        XCTAssertEqual(currentSessionID(of: monitor), session.sessionUUID.rawValue.uuidString)
    }

    func testControl_aCollectedSessionReportsItsIDFromTheStart() throws {
        let monitor = monitor(sessionSampleRate: 100, sessionOnError: true)
        let session = try XCTUnwrap(monitor.scopes.activeSession)

        XCTAssertEqual(currentSessionID(of: monitor), session.sessionUUID.rawValue.uuidString)
    }

    func testControl_aSessionLeftOutWithTheSwitchOff_reportsNoID() {
        let monitor = monitor(sessionSampleRate: 0, sessionOnError: false)

        XCTAssertNil(currentSessionID(of: monitor))
    }
}
