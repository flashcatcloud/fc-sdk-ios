/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import XCTest
import DatadogInternal
@testable import DatadogRUM
@testable import TestUtilities

class RemoteSamplingReceiverTests: XCTestCase {
    private let featureScope = FeatureScopeMock()

    private lazy var monitor = Monitor(
        dependencies: .mockWith(featureScope: featureScope),
        dateProvider: DateProviderMock()
    )

    private lazy var receiver = RemoteSamplingReceiver(monitor: monitor)

    func testImmediateChangeMessageEndsRunningSession() throws {
        monitor.notifySDKInit()
        try XCTSkipIf(monitor.scopes.activeSession == nil, "no session to end")

        let handled = receiver.receive(message: .payload(RemoteSamplingChangedMessage(activation: .immediate)), from: NOPDatadogCore())

        XCTAssertTrue(handled)
        XCTAssertNil(monitor.scopes.activeSession, "the session ends so the next one starts under the new rates")
    }

    func testImmediateChangeMessageLeavesAForcedSessionRunning() throws {
        monitor.notifySDKInit()
        monitor.setForcedSession()
        let sessionBefore = try XCTUnwrap(monitor.scopes.activeSession?.sessionUUID)

        _ = receiver.receive(message: .payload(RemoteSamplingChangedMessage(activation: .immediate)), from: NOPDatadogCore())

        XCTAssertEqual(
            monitor.scopes.activeSession?.sessionUUID,
            sessionBefore,
            "a forced session is collected whatever the rates say, so ending it would only buy an identical one"
        )
    }

    func testContextMessageKeepsCustomValuesForHostApp() throws {
        let rates = RemoteSamplingRates(
            sessionSampleRate: nil,
            version: 42,
            custom: #"{"viplist":["u-1"],"flag":true}"#
        )
        var context: DatadogContext = .mockAny()
        context.set(additionalContext: rates)

        let handled = receiver.receive(message: .context(context), from: NOPDatadogCore())

        XCTAssertFalse(handled, "context updates are broadcast, not claimed")
        let remoteConfig = try XCTUnwrap(monitor.getRemoteConfig())
        XCTAssertEqual(remoteConfig["viplist"] as? [String], ["u-1"])
        XCTAssertEqual(remoteConfig["flag"] as? Bool, true)
    }

    func testKillSwitchDropsCustomValuesForHostApp() {
        var context: DatadogContext = .mockAny()
        context.set(additionalContext: RemoteSamplingRates(
            sessionSampleRate: nil,
            version: 42,
            custom: #"{"a":1}"#
        ))
        _ = receiver.receive(message: .context(context), from: NOPDatadogCore())
        XCTAssertNotNil(monitor.getRemoteConfig())

        // Kill switch: values cleared, version kept, custom gone.
        context.set(additionalContext: RemoteSamplingRates(
            sessionSampleRate: nil,
            version: 43,
            custom: nil
        ))
        _ = receiver.receive(message: .context(context), from: NOPDatadogCore())

        XCTAssertNil(monitor.getRemoteConfig())
    }

    func testNOPMonitorAnswersNilRemoteConfig() {
        XCTAssertNil(NOPMonitor().getRemoteConfig())
    }
}
