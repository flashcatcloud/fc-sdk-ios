/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import XCTest
@testable import TestUtilities
import DatadogInternal
@_spi(objc)
@testable import DatadogRUM

class DDRUMTests: XCTestCase {
    private var core: FeatureRegistrationCoreMock! // swiftlint:disable:this implicitly_unwrapped_optional

    override func setUp() {
        super.setUp()
        core = FeatureRegistrationCoreMock()
        CoreRegistry.register(default: core)
    }

    override func tearDown() {
        CoreRegistry.unregisterDefault()
        core = nil
        super.tearDown()
    }

    func testWhenNotEnabled() {
        XCTAssertTrue(objc_RUMMonitor.shared().swiftRUMMonitor is NOPMonitor)
    }

    func testWhenEnabled() {
        objc_RUM.enable(with: objc_RUMConfiguration(applicationID: "app-id"))
        XCTAssertTrue(objc_RUMMonitor.shared().swiftRUMMonitor is Monitor)
    }

    func testForcedSessionAndRemoteConfigReachTheSwiftMonitor() throws {
        // Built on a synchronous feature scope so this measures the bridge and not the queue hop
        // behind `Monitor.process(command:)`. What forcing then does to a session is
        // `RUMApplicationScopeTests`' business; all this file has to show is that the call arrives.
        let monitor = Monitor(
            dependencies: .mockWith(featureScope: FeatureScopeMock()),
            dateProvider: DateProviderMock()
        )
        let objcMonitor = objc_RUMMonitor(swiftRUMMonitor: monitor)

        XCTAssertNil(objcMonitor.getRemoteConfig(), "nothing published yet, so nothing to read")

        monitor.remoteConfigCustom = #"{"viplist":["u-1"]}"#
        let remoteConfig: [String: Any] = try XCTUnwrap(objcMonitor.getRemoteConfig(), "custom values cross the bridge decoded")
        XCTAssertEqual(remoteConfig["viplist"] as? [String], ["u-1"])

        monitor.notifySDKInit()
        objcMonitor.setForcedSession()
        XCTAssertTrue(monitor.scopes.isForcedSession, "forcing reaches the scope that draws sessions")
    }

    func testNoOpMonitorAnswersTheForkedAPIsSafely() {
        // Reached whenever the application calls before `enable`, which ObjC callers do as easily
        // as Swift ones.
        let objcMonitor = objc_RUMMonitor.shared()
        XCTAssertTrue(objcMonitor.swiftRUMMonitor is NOPMonitor)

        XCTAssertNil(objcMonitor.getRemoteConfig())
        objcMonitor.setForcedSession()
    }
}
