/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import XCTest
@testable import DatadogCrashReporting

class CrashReportingConfigurationTests: XCTestCase {
    func testConfiguration_DefaultsToInProcessSymbolicationOn() {
        // In-process symbolication is on by default (Bugly parity): readable stacks without a dSYM.
        XCTAssertTrue(CrashReporting.Configuration().symbolicateInProcess)
    }

    func testConfiguration_CanDisableInProcessSymbolication() {
        XCTAssertFalse(CrashReporting.Configuration(symbolicateInProcess: false).symbolicateInProcess)
    }
}
