/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation
@_spi(objc)
import FlashcatInternal

@objc(DDTrackingConsent)
@objcMembers
@_spi(objc)
public final class objc_TrackingConsent: NSObject {
    internal let sdkConsent: TrackingConsent

    internal init(sdkConsent: TrackingConsent) {
        self.sdkConsent = sdkConsent
    }

    // MARK: - Public

    public static func granted() -> objc_TrackingConsent { .init(sdkConsent: .granted) }

    public static func notGranted() -> objc_TrackingConsent { .init(sdkConsent: .notGranted) }

    public static func pending() -> objc_TrackingConsent { .init(sdkConsent: .pending) }
}

@objc(DDDatadog)
@objcMembers
@_spi(objc)
public final class objc_Datadog: NSObject {
    // MARK: - Public

    public static func initialize(
        configuration: objc_Configuration,
        trackingConsent: objc_TrackingConsent
    ) {
        Flashcat.initialize(
            with: configuration.sdkConfiguration,
            trackingConsent: trackingConsent.sdkConsent
        )
    }

    public static func setVerbosityLevel(_ verbosityLevel: objc_CoreLoggerLevel) {
        switch verbosityLevel {
        case .debug: Flashcat.verbosityLevel = .debug
        case .warn: Flashcat.verbosityLevel = .warn
        case .error: Flashcat.verbosityLevel = .error
        case .critical: Flashcat.verbosityLevel = .critical
        case .none: Flashcat.verbosityLevel = nil
        }
    }

    public static func verbosityLevel() -> objc_CoreLoggerLevel {
        switch Flashcat.verbosityLevel {
        case .debug: return .debug
        case .warn: return .warn
        case .error: return .error
        case .critical: return .critical
        case .none: return .none
        }
    }

    public static func setUserInfo(userId: String, name: String? = nil, email: String? = nil, extraInfo: [String: Any] = [:]) {
        Flashcat.setUserInfo(id: userId, name: name, email: email, extraInfo: extraInfo.dd.swiftAttributes)
    }

    public static func clearUserInfo() {
        Flashcat.clearUserInfo()
    }

    public static func addUserExtraInfo(_ extraInfo: [String: Any]) {
        Flashcat.addUserExtraInfo(extraInfo.dd.swiftAttributes)
    }

    public static func setAccountInfo(accountId: String, name: String? = nil, extraInfo: [String: Any] = [:]) {
        Flashcat.setAccountInfo(id: accountId, name: name, extraInfo: extraInfo.dd.swiftAttributes)
    }

    public static func addAccountExtraInfo(_ extraInfo: [String: Any]) {
        Flashcat.addAccountExtraInfo(extraInfo.dd.swiftAttributes)
    }

    public static func clearAccountInfo() {
        Flashcat.clearAccountInfo()
    }

    public static func setTrackingConsent(consent: objc_TrackingConsent) {
        Flashcat.set(trackingConsent: consent.sdkConsent)
    }

    public static func isInitialized() -> Bool {
        return Flashcat.isInitialized()
    }

    public static func stopInstance() {
        Flashcat.stopInstance()
    }

    public static func clearAllData() {
        Flashcat.clearAllData()
    }

#if DD_SDK_COMPILED_FOR_TESTING
    public static func flushAndDeinitialize() {
        Flashcat.flushAndDeinitialize()
    }
#endif
}
