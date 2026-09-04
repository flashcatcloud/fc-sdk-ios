/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import XCTest
import TestUtilities
import DatadogInternal
@testable import DatadogCore
@_spi(objc)
@testable import DatadogRUM

class DDRUMConfigurationTests: XCTestCase {
    private var objc = objc_RUMConfiguration(applicationID: "app-id")
    private var swift: RUM.Configuration { objc.swiftConfig }

    func testApplicationID() {
        objc = objc_RUMConfiguration(applicationID: "rum-app-id")
        XCTAssertEqual(swift.applicationID, "rum-app-id")
    }

    func testSessionSampleRate() {
        objc.sessionSampleRate = 30
        XCTAssertEqual(objc.sessionSampleRate, 30)
        XCTAssertEqual(swift.sessionSampleRate, 30)
    }

    func testTelemetrySampleRate() {
        objc.telemetrySampleRate = 30
        XCTAssertEqual(objc.telemetrySampleRate, 30)
        XCTAssertEqual(swift.telemetrySampleRate, 30)
    }

    func testRemoteConfigurationEnabled() {
        XCTAssertFalse(objc.remoteConfigurationEnabled, "off unless the application asks for it")
        objc.remoteConfigurationEnabled = true
        XCTAssertTrue(objc.remoteConfigurationEnabled)
        XCTAssertTrue(swift.remoteConfigurationEnabled)
    }

    func testBeforeSampling() throws {
        var seen: objc_RUMBeforeSamplingContext?
        let block: (objc_RUMBeforeSamplingContext) -> NSNumber? = { context in
            seen = context
            return NSNumber(value: 100)
        }

        objc.beforeSampling = block

        XCTAssertNotNil(objc.beforeSampling, "the getter hands back what the caller set")
        let swiftHook = try XCTUnwrap(swift.beforeSampling, "the block reaches the Swift configuration")

        let override = swiftHook(BeforeSamplingContext(sessionSampleRate: 20, custom: ["vip": ["u-1"]]))

        XCTAssertEqual(override, 100)
        XCTAssertEqual(seen?.sessionSampleRate, 20, "the rate that would apply crosses the bridge")
        XCTAssertEqual(seen?.custom?["vip"] as? [String], ["u-1"], "so do the console's custom values")
    }

    func testBeforeSamplingReturningNilLeavesTheDrawAlone() throws {
        // `nil` is how "do not interfere" is said, which is why the block returns NSNumber rather
        // than a float: zero is a rate someone may well mean.
        objc.beforeSampling = { _ in nil }

        let swiftHook = try XCTUnwrap(swift.beforeSampling)

        XCTAssertNil(swiftHook(BeforeSamplingContext(sessionSampleRate: 20, custom: nil)))
    }

    func testBeforeSamplingSurvivesAnExceptionRaisedByTheApplication() throws {
        // The block is the one piece of application code the SDK runs synchronously inside session
        // creation, so an `NSException` raised by it comes down through the SDK's own stack. An
        // application making a mistake about which sessions to keep must not be fatal to that
        // application.
        //
        // The handler that turns an Objective-C exception into a Swift error is installed by
        // `Datadog.initialize`; installed here as well so this test does not depend on some other
        // test having run first. Without it `objc_rethrow` is a pass-through, and this test does
        // not fail — it takes the whole test process down with it, which is the clearest evidence
        // available that the guard is what is being measured.
        registerObjcExceptionHandlerOnce()

        var didRaise = false
        objc.beforeSampling = { _ in
            didRaise = true
            NSException(
                name: .invalidArgumentException,
                reason: "the application reached for something the console never sent",
                userInfo: nil
            ).raise()
            return NSNumber(value: 0) // unreachable; a raised exception does not return
        }

        let swiftHook = try XCTUnwrap(swift.beforeSampling)
        let override = swiftHook(BeforeSamplingContext(sessionSampleRate: 20, custom: nil))

        XCTAssertTrue(didRaise, "the block really did raise — without this the test could pass having never exercised the guard")
        XCTAssertNil(override, "a block that raises is read exactly as one that returned nil, so the incoming rate applies")
    }

    func testBeforeSamplingClearedAgain() {
        objc.beforeSampling = { _ in NSNumber(value: 100) }
        objc.beforeSampling = nil

        XCTAssertNil(objc.beforeSampling)
        XCTAssertNil(swift.beforeSampling, "clearing it on the bridge clears it underneath")
    }

    func testUIKitViewsPredicate() {
        class ObjcPredicate: objc_UIKitRUMViewsPredicate {
            func rumView(for viewController: UIViewController) -> objc_RUMView? { nil }
        }
        let predicate = ObjcPredicate()
        objc.uiKitViewsPredicate = predicate
        XCTAssertIdentical(objc.uiKitViewsPredicate, predicate)
        XCTAssertNotNil(swift.uiKitViewsPredicate)
    }

    func testUIKitActionsPredicate() {
        class ObjcPredicate: objc_UIKitRUMActionsPredicate & objc_UITouchRUMActionsPredicate & objc_UIPressRUMActionsPredicate {
            func rumAction(targetView: UIView) -> objc_RUMAction? { nil }
            func rumAction(press type: UIPress.PressType, targetView: UIView) -> objc_RUMAction? { nil }
        }
        let predicate = ObjcPredicate()
        objc.uiKitActionsPredicate = predicate
        XCTAssertIdentical(objc.uiKitActionsPredicate, predicate)
        XCTAssertNotNil(swift.uiKitActionsPredicate)
    }

    func testSetDDRUMURLSessionTrackingWithFirstPartyHosts() {
        let tracking = objc_URLSessionTracking()

        objc.setURLSessionTracking(tracking)
        DDAssertReflectionEqual(swift.urlSessionTracking, RUM.Configuration.URLSessionTracking())

        tracking.setFirstPartyHostsTracing(.init(hosts: ["foo.com"]))
        objc.setURLSessionTracking(tracking)
        DDAssertReflectionEqual(swift.urlSessionTracking, .init(firstPartyHostsTracing: .trace(hosts: ["foo.com"])))

        tracking.setFirstPartyHostsTracing(.init(hosts: ["foo.com"], sampleRate: 99))
        objc.setURLSessionTracking(tracking)
        DDAssertReflectionEqual(swift.urlSessionTracking, .init(firstPartyHostsTracing: .trace(hosts: ["foo.com"], sampleRate: 99)))

        tracking.setFirstPartyHostsTracing(.init(hostsWithHeaderTypes: ["foo.com": [.b3, .datadog]]))
        objc.setURLSessionTracking(tracking)
        DDAssertReflectionEqual(swift.urlSessionTracking, .init(firstPartyHostsTracing: .traceWithHeaders(hostsWithHeaders: ["foo.com": [.b3, .datadog]])))

        tracking.setFirstPartyHostsTracing(.init(hostsWithHeaderTypes: ["foo.com": [.b3, .datadog]], sampleRate: 99))
        objc.setURLSessionTracking(tracking)
        DDAssertReflectionEqual(swift.urlSessionTracking, .init(firstPartyHostsTracing: .traceWithHeaders(hostsWithHeaders: ["foo.com": [.b3, .datadog]], sampleRate: 99)))
    }

    func testSetDDRUMURLSessionTrackingWithResourceAttributesProvider() {
        let tracking = objc_URLSessionTracking()

        objc.setURLSessionTracking(tracking)
        XCTAssertNil(swift.urlSessionTracking?.resourceAttributesProvider)

        tracking.setResourceAttributesProvider { _, _, _, _ in nil }
        objc.setURLSessionTracking(tracking)
        XCTAssertNotNil(swift.urlSessionTracking?.resourceAttributesProvider)
    }

    func testFrustrationsTracking() {
        let random: Bool = .mockRandom()
        objc.trackFrustrations = random
        XCTAssertEqual(objc.trackFrustrations, random)
        XCTAssertEqual(swift.trackFrustrations, random)
    }

    func testBackgroundEventsTracking() {
        let random: Bool = .mockRandom()
        objc.trackBackgroundEvents = random
        XCTAssertEqual(objc.trackBackgroundEvents, random)
        XCTAssertEqual(swift.trackBackgroundEvents, random)
    }

    func testLongTaskThreshold() {
        let random: TimeInterval = .mockRandom()
        objc.longTaskThreshold = random
        XCTAssertEqual(objc.longTaskThreshold, random)
        XCTAssertEqual(swift.longTaskThreshold, random)
    }

    func testAppHangThreshold() {
        let random: TimeInterval = .mockRandom(min: 0.01, max: .greatestFiniteMagnitude)
        objc.appHangThreshold = random
        XCTAssertEqual(objc.appHangThreshold, random)
        XCTAssertEqual(swift.appHangThreshold, random)
    }

    func testAppHangThresholdDisable() {
        objc.appHangThreshold = 0
        XCTAssertEqual(objc.appHangThreshold, 0)
        XCTAssertEqual(swift.appHangThreshold, nil)
    }

    func testVitalsUpdateFrequency() {
        objc.vitalsUpdateFrequency = .frequent
        XCTAssertEqual(swift.vitalsUpdateFrequency, .frequent)

        objc.vitalsUpdateFrequency = .never
        XCTAssertNil(swift.vitalsUpdateFrequency)
    }

    func testEventMappers() {
        let swiftViewEvent: RUMViewEvent = .mockRandom()
        let swiftResourceEvent: RUMResourceEvent = .mockRandom()
        let swiftActionEvent: RUMActionEvent = .mockAny()
        let swiftErrorEvent: RUMErrorEvent = .mockRandom()
        let swiftLongTaskEvent: RUMLongTaskEvent = .mockRandom()

        objc.setViewEventMapper { objcViewEvent in
            DDAssertReflectionEqual(objcViewEvent.swiftModel, swiftViewEvent)
            objcViewEvent.view.url = "redacted view.url"
            return objcViewEvent
        }

        objc.setResourceEventMapper { objcResourceEvent in
            DDAssertReflectionEqual(objcResourceEvent.swiftModel, swiftResourceEvent)
            objcResourceEvent.view.url = "redacted view.url"
            objcResourceEvent.resource.url = "redacted resource.url"
            return objcResourceEvent
        }

        objc.setActionEventMapper { objcActionEvent in
            DDAssertReflectionEqual(objcActionEvent.swiftModel, swiftActionEvent)
            objcActionEvent.view.url = "redacted view.url"
            objcActionEvent.action.target?.name = "redacted action.target.name"
            return objcActionEvent
        }

        objc.setErrorEventMapper { objcErrorEvent in
            DDAssertReflectionEqual(objcErrorEvent.swiftModel, swiftErrorEvent)
            objcErrorEvent.view.url = "redacted view.url"
            objcErrorEvent.error.message = "redacted error.message"
            objcErrorEvent.error.resource?.url = "redacted error.resource.url"
            return objcErrorEvent
        }

        objc.setLongTaskEventMapper { objcLongTaskEvent in
            DDAssertReflectionEqual(objcLongTaskEvent.swiftModel, swiftLongTaskEvent)
            objcLongTaskEvent.view.url = "redacted view.url"
            return objcLongTaskEvent
        }

        let redactedSwiftViewEvent = swift.viewEventMapper?(swiftViewEvent)
        let redactedSwiftResourceEvent = swift.resourceEventMapper?(swiftResourceEvent)
        let redactedSwiftActionEvent = swift.actionEventMapper?(swiftActionEvent)
        let redactedSwiftErrorEvent = swift.errorEventMapper?(swiftErrorEvent)
        let redactedSwiftLongTaskEvent = swift.longTaskEventMapper?(swiftLongTaskEvent)

        XCTAssertEqual(redactedSwiftViewEvent?.view.url, "redacted view.url")
        XCTAssertEqual(redactedSwiftResourceEvent?.view.url, "redacted view.url")
        XCTAssertEqual(redactedSwiftResourceEvent?.resource.url, "redacted resource.url")
        XCTAssertEqual(redactedSwiftActionEvent?.view.url, "redacted view.url")
        XCTAssertEqual(redactedSwiftActionEvent?.action.target?.name, "redacted action.target.name")
        XCTAssertEqual(redactedSwiftErrorEvent?.view.url, "redacted view.url")
        XCTAssertEqual(redactedSwiftErrorEvent?.error.message, "redacted error.message")
        XCTAssertEqual(redactedSwiftErrorEvent?.error.resource?.url, "redacted error.resource.url")
        XCTAssertEqual(redactedSwiftLongTaskEvent?.view.url, "redacted view.url")
    }

    func testOnSessionStart() {
        objc.onSessionStart = { _, _ in }
        XCTAssertNotNil(swift.onSessionStart)
    }

    func testCustomEndpoint() {
        let random: URL = .mockRandom()
        objc.customEndpoint = random
        XCTAssertEqual(objc.customEndpoint, random)
        XCTAssertEqual(swift.customEndpoint, random)
    }
}
