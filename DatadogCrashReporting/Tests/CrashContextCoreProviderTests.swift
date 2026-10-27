/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import XCTest
import TestUtilities
import DatadogInternal

@testable import DatadogCrashReporting

class CrashContextCoreProviderTests: XCTestCase {
    // MARK: - Context Update Tests

    func testItUpdatesContextFromDatadogContext() {
        // Given
        let provider = CrashContextCoreProvider()
        let core = PassthroughCoreMock()
        let context: DatadogContext = .mockWith(
            service: "test-service",
            env: "test-env",
            version: "1.0.0"
        )

        // When
        let message: FeatureMessage = .context(context)
        XCTAssertTrue(provider.receive(message: message, from: core))
        provider.flush()

        // Then
        XCTAssertNotNil(provider.currentCrashContext)
        XCTAssertEqual(provider.currentCrashContext?.service, "test-service")
        XCTAssertEqual(provider.currentCrashContext?.env, "test-env")
        XCTAssertEqual(provider.currentCrashContext?.version, "1.0.0")
    }

    func testItDoesNotUpdateContextWhenContextIsUnchanged() {
        // Given
        let provider = CrashContextCoreProvider()
        let core = PassthroughCoreMock()
        let context: DatadogContext = .mockWith(service: "test-service")
        var callbackCount = 0

        provider.onCrashContextChange = { _ in
            callbackCount += 1
        }

        // When
        XCTAssertTrue(provider.receive(message: .context(context), from: core))
        XCTAssertTrue(provider.receive(message: .context(context), from: core))
        provider.flush()

        // Then - callback should only be called once for the actual change
        XCTAssertEqual(callbackCount, 1)
    }

    // MARK: - RUM State Tests

    func testItStoresRUMStateFromDatadogContext() throws {
        // Given
        let provider = CrashContextCoreProvider()
        let core = PassthroughCoreMock()
        let rumContext = RUMFatalErrorContext(sessionState: .mockRandom(), view: .mockRandom(), globalAttributes: .mockRandom())

        // When
        XCTAssertTrue(provider.receive(message: .context(.mockAny()), from: core))
        XCTAssertTrue(provider.receive(message: .context(.mockWith(rumContext: rumContext)), from: core))
        provider.flush()

        // Then
        let crashContext = try XCTUnwrap(provider.currentCrashContext)
        XCTAssertEqual(crashContext.lastRUMSessionState, rumContext.sessionState)
        XCTAssertEqual(crashContext.lastRUMViewEvent?.view.id, rumContext.view?.view.id)
        DDAssertJSONEqual(crashContext.lastRUMAttributes, rumContext.globalAttributes)
    }

    func testItResetsRUMViewEventWhenRUMStateHasNoView() throws {
        // Given
        let provider = CrashContextCoreProvider()
        let core = PassthroughCoreMock()
        let sessionState: RUMSessionState = .mockRandom()
        let withView = RUMFatalErrorContext(sessionState: sessionState, view: .mockRandom(), globalAttributes: nil)
        let withoutView = RUMFatalErrorContext(sessionState: sessionState, view: nil, globalAttributes: nil)

        XCTAssertTrue(provider.receive(message: .context(.mockWith(rumContext: withView)), from: core))
        provider.flush()
        XCTAssertNotNil(provider.currentCrashContext?.lastRUMViewEvent)

        // When
        XCTAssertTrue(provider.receive(message: .context(.mockWith(rumContext: withoutView)), from: core))
        provider.flush()

        // Then
        XCTAssertNil(provider.currentCrashContext?.lastRUMViewEvent)
        XCTAssertEqual(provider.currentCrashContext?.lastRUMSessionState, sessionState)
    }

    func testItNotifiesOnlyWhenRUMStateIsReplaced() {
        // Given
        let provider = CrashContextCoreProvider()
        let core = PassthroughCoreMock()
        let first = RUMFatalErrorContext(sessionState: .mockRandom(), view: .mockRandom(), globalAttributes: nil)
        let second = RUMFatalErrorContext(sessionState: first.sessionState, view: .mockRandom(), globalAttributes: nil)
        let context: DatadogContext = .mockAny()
        var callbackCount = 0
        provider.onCrashContextChange = { _ in callbackCount += 1 }

        // When
        XCTAssertTrue(provider.receive(message: .context(context.with(rumContext: first)), from: core))
        XCTAssertTrue(provider.receive(message: .context(context.with(rumContext: first)), from: core)) // RUM state unchanged
        XCTAssertTrue(provider.receive(message: .context(context.with(rumContext: second)), from: core))
        provider.flush()

        // Then
        XCTAssertEqual(callbackCount, 2, "It must notify the first context and the RUM change, not the unchanged one")
    }

    // MARK: - Compatibility

    /// A crash context written by SDK 0.8.0 (RUM state received as messages), as read back from a crash report.
    func testItDecodesCrashContextWrittenBySDK0_8_0() throws {
        let data = """
        {
            "appLaunchDate": "2026-10-27T16:07:08.590Z",
            "buildNumber": "1",
            "device": {
                "architecture": "arm64e",
                "brand": "Apple",
                "brightness_level": 0.5,
                "locale": "en-US",
                "locales": [
                    "en-US",
                    "en-US"
                ],
                "logical_cpu_count": 10,
                "model": "iPhone17,3 Simulator",
                "name": "iPhone",
                "power_saving_mode": false,
                "time_zone": "UTC",
                "total_ram": 16384,
                "type": "mobile"
            },
            "env": "test",
            "lastIsAppInForeground": true,
            "lastRUMAttributes": {
                "attribute": "run-1"
            },
            "lastRUMSessionState": {
                "hasTrackedAnyView": true,
                "isInitialSession": true,
                "sessionUUID": "B355B61D-2026-44BC-A766-B194519FCAE2"
            },
            "lastRUMViewEvent": {
                "_dd": {
                    "configuration": {
                        "session_sample_rate": 100
                    },
                    "document_version": 2,
                    "format_version": 2,
                    "replay_stats": {},
                    "session": {
                        "plan": 1,
                        "session_precondition": "user_app_launch"
                    }
                },
                "application": {
                    "current_locale": "en-US",
                    "id": "rum-application-id"
                },
                "build_version": "1",
                "connectivity": {
                    "interfaces": [
                        "wifi"
                    ],
                    "status": "connected"
                },
                "context": {
                    "attribute": "run-1"
                },
                "date": 1793117228993,
                "ddtags": "sdk_version:0.8.0,version:1.0.0,service:app-ios,env:test",
                "device": {
                    "architecture": "arm64e",
                    "brand": "Apple",
                    "brightness_level": 0.5,
                    "locale": "en-US",
                    "locales": [
                        "en-US",
                        "en-US"
                    ],
                    "logical_cpu_count": 10,
                    "model": "iPhone17,3 Simulator",
                    "name": "iPhone",
                    "power_saving_mode": false,
                    "time_zone": "UTC",
                    "total_ram": 16384,
                    "type": "mobile"
                },
                "feature_flags": {},
                "os": {
                    "build": "24F74",
                    "name": "iOS",
                    "version": "18.6",
                    "version_major": "18"
                },
                "service": "app-ios",
                "session": {
                    "has_replay": false,
                    "id": "b355b61d-2026-44bc-a766-b194519fcae2",
                    "is_active": true,
                    "type": "user"
                },
                "source": "ios",
                "type": "view",
                "usr": {
                    "anonymous_id": "99f4fb90-9f73-4d17-a78f-1b44765e8058",
                    "id": "run-1",
                    "name": "user-name"
                },
                "version": "1.0.0",
                "view": {
                    "action": {
                        "count": 0
                    },
                    "cpu_ticks_count": 0,
                    "crash": {
                        "count": 0
                    },
                    "custom_timings": {},
                    "error": {
                        "count": 0
                    },
                    "frozen_frame": {
                        "count": 0
                    },
                    "frustration": {
                        "count": 0
                    },
                    "id": "78b5b309-ae08-4b9e-8b48-4d2137d5beac",
                    "is_active": true,
                    "is_slow_rendered": true,
                    "long_task": {
                        "count": 1
                    },
                    "memory_average": 19679608,
                    "memory_max": 19679608,
                    "name": "Home",
                    "refresh_rate_average": 4.77729,
                    "refresh_rate_min": 4.77729,
                    "resource": {
                        "count": 0
                    },
                    "slow_frames": [
                        {
                            "duration": 192657125,
                            "start": 16666667
                        }
                    ],
                    "time_spent": 247675896,
                    "url": "home"
                }
            },
            "networkConnectionInfo": {
                "availableInterfaces": [
                    "wifi"
                ],
                "isConstrained": false,
                "isExpensive": false,
                "reachability": "yes",
                "supportsIPv4": false,
                "supportsIPv6": false
            },
            "os": {
                "build": "24F74",
                "name": "iOS",
                "version": "18.6",
                "version_major": "18"
            },
            "sdkVersion": "0.8.0",
            "serverTimeOffset": 1.11833,
            "service": "app-ios",
            "source": "ios",
            "trackingConsent": {
                "granted": {}
            },
            "userInfo": {
                "anonymousId": "99f4fb90-9f73-4d17-a78f-1b44765e8058",
                "id": "run-1",
                "name": "user-name"
            },
            "version": "1.0.0"
        }
        """.data(using: .utf8)!

        let crashContext = try CrashReportingFeature.crashContextDecoder.decode(CrashContext.self, from: data)

        XCTAssertEqual(crashContext.service, "app-ios")
        XCTAssertEqual(crashContext.trackingConsent, .granted)
        XCTAssertEqual(crashContext.userInfo?.id, "run-1")
        XCTAssertEqual(crashContext.lastRUMSessionState?.sessionUUID.uuidString.lowercased(), "b355b61d-2026-44bc-a766-b194519fcae2")
        XCTAssertEqual(crashContext.lastRUMViewEvent?.view.name, "Home")
        XCTAssertEqual(crashContext.lastRUMViewEvent?.session.id, "b355b61d-2026-44bc-a766-b194519fcae2")
        XCTAssertNotNil(crashContext.lastRUMAttributes?.contextInfo["attribute"])
    }

    // MARK: - Callback Tests

    func testItInvokesCallbackOnContextChange() {
        // Given
        let provider = CrashContextCoreProvider()
        let core = PassthroughCoreMock()
        let context: DatadogContext = .mockWith(service: "test-service")
        var receivedContext: CrashContext?

        provider.onCrashContextChange = { crashContext in
            receivedContext = crashContext
        }
        provider.flush()

        // When
        XCTAssertTrue(provider.receive(message: .context(context), from: core))
        provider.flush()

        // Then
        XCTAssertNotNil(receivedContext)
        XCTAssertEqual(receivedContext?.service, "test-service")
    }

    // MARK: - Message Handling Tests

    func testItReturnsFalseForUnhandledMessages() {
        // Given
        let provider = CrashContextCoreProvider()
        let core = PassthroughCoreMock()
        let unrelatedMessage = "some unrelated message"

        // When
        let handled = provider.receive(message: .payload(unrelatedMessage), from: core)

        // Then
        XCTAssertFalse(handled)
    }
}

private extension DatadogContext {
    static func mockWith(rumContext: RUMFatalErrorContext?) -> DatadogContext {
        DatadogContext.mockAny().with(rumContext: rumContext)
    }

    func with(rumContext: RUMFatalErrorContext?) -> DatadogContext {
        var context = self
        context.set(additionalContext: rumContext)
        return context
    }
}
