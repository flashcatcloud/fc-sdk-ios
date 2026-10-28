/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation
import DatadogInternal

@testable import DatadogLogs
@testable import DatadogRUM
@testable import DatadogCrashReporting
@testable import DatadogCore

extension CrashReportingFeature {
    /// Mocks the Crash Reporting feature instance which doesn't load crash reports.
    public static func mockNoOp(
            core: DatadogCoreProtocol = NOPDatadogCore(),
            crashReportingPlugin: CrashReportingPlugin = NOPCrashReportingPlugin()
    ) -> Self {
        return .mockWith(
            integration: MessageBusSender(core: core),
            crashReportingPlugin: crashReportingPlugin
        )
    }

    /// Pending crash reports are read right after `start()` (no `processingDelay`), unless specified otherwise.
    public static func mockWith(
        integration: CrashReportSender,
        crashReportingPlugin: CrashReportingPlugin = NOPCrashReportingPlugin(),
        crashContextProvider: CrashContextProvider = CrashContextProviderMock(),
        messageReceiver: FeatureMessageReceiver = NOPFeatureMessageReceiver(),
        telemetry: Telemetry = NOPTelemetry(),
        processingDelay: TimeInterval = 0
    ) -> Self {
        .init(
            crashReportingPlugin: crashReportingPlugin,
            crashContextProvider: crashContextProvider,
            sender: integration,
            messageReceiver: messageReceiver,
            telemetry: telemetry,
            processingDelay: processingDelay
        )
    }
}

public class CrashReportingPluginMock: CrashReportingPlugin {
    /// The value of `crashedLastLaunch`.
    public var crashedLastLaunch = false
    /// The value of `unreadLaunches`.
    public var unreadLaunches = 0
    /// The crash reports held by this plugin, oldest first. A report is removed once processed, as by `KSCrashPlugin`.
    @ReadWriteLock
    public var pendingCrashReports: [DDCrashReport] = []
    /// The crash reports deleted once processed, in order.
    @ReadWriteLock
    public var deletedCrashReports: [DDCrashReport] = []
    /// How many times the pending crash reports were read.
    @ReadWriteLock
    public var readCount = 0
    /// Custom app state data injected to the plugin.
    public var injectedContextData: Data?
    /// Custom backtrace reporter injected to the plugin.
    public var injectedBacktraceReporter: BacktraceReporting?

    public init() {}

    public func readPendingCrashReports(process: (DDCrashReport) -> Bool) {
        readCount += 1
        var kept: [DDCrashReport] = []
        for report in pendingCrashReports {
            if process(report) {
                deletedCrashReports.append(report)
            } else {
                kept.append(report)
            }
        }
        pendingCrashReports = kept
        didReadPendingCrashReports?()
    }

    /// Notifies the `readPendingCrashReports(process:)` return.
    public var didReadPendingCrashReports: (() -> Void)?

    public func inject(context: Data) {
        injectedContextData = context
        didInjectContext?()
    }

    /// Notifies the `inject(context:)` return.
    public var didInjectContext: (() -> Void)?

    public var backtraceReporter: BacktraceReporting? { injectedBacktraceReporter }
}

public class NOPCrashReportingPlugin: CrashReportingPlugin {
    public var crashedLastLaunch: Bool { false }
    public func readPendingCrashReports(process: (DDCrashReport) -> Bool) {}
    public func inject(context: Data) {}
    public var backtraceReporter: BacktraceReporting? { nil }

    public init() {}
}

public class CrashContextProviderMock: CrashContextProvider {
    public private(set) var currentCrashContext: CrashContext?
    public var onCrashContextChange: (CrashContext) -> Void

    public init(initialCrashContext: CrashContext? = .mockAny()) {
        self.currentCrashContext = initialCrashContext
        self.onCrashContextChange = { _ in }
    }
}

public class CrashReportSenderMock: CrashReportSender {
    /// All crash reports sent, in order.
    public private(set) var sentCrashReports: [(report: DDCrashReport, context: CrashContext)] = []
    /// The last crash report sent.
    public var sentCrashReport: DDCrashReport? { sentCrashReports.last?.report }
    /// The context of the last crash report sent.
    public var sentCrashContext: CrashContext? { sentCrashReports.last?.context }
    /// All launch reports sent, in order.
    public private(set) var sentLaunchReports: [LaunchReport] = []
    /// What `send(report:with:)` returns: whether the crash was processed.
    public var processesCrashReports = true

    public init() {}

    public func send(report: DDCrashReport, with context: CrashContext) -> Bool {
        sentCrashReports.append((report, context))
        didSendCrashReport?()
        return processesCrashReports
    }

    public var didSendCrashReport: (() -> Void)?

    public func send(launch: DatadogInternal.LaunchReport) {
        sentLaunchReports.append(launch)
    }
}

public class CrashReceiverMock: FeatureMessageReceiver {
    public var receivedCrash: Crash?
    /// What the receiver reports through the crash completion.
    public var processes = true

    public func receive(message: FeatureMessage, from core: DatadogCoreProtocol) -> Bool {
        guard case let .payload(crash as Crash) = message else {
            return false
        }
        receivedCrash = crash
        crash.completion(processes)
        return true
    }

    public init() {}
}

extension CrashContext {
    public static func mockAny() -> CrashContext {
        return mockWith()
    }

    public static func mockWith(
        serverTimeOffset: TimeInterval = .zero,
        service: String = .mockAny(),
        env: String = .mockAny(),
        version: String = .mockAny(),
        buildNumber: String = .mockAny(),
        device: Device = .mockAny(),
        os: OperatingSystem = .mockAny(),
        sdkVersion: String = .mockAny(),
        source: String = .mockAny(),
        trackingConsent: TrackingConsent = .granted,
        userInfo: UserInfo? = .mockAny(),
        accountInfo: AccountInfo? = nil,
        networkConnectionInfo: NetworkConnectionInfo? = .mockAny(),
        carrierInfo: CarrierInfo? = .mockAny(),
        lastRUMViewEvent: RUMViewEvent? = nil,
        lastRUMSessionState: RUMSessionState? = nil,
        lastIsAppInForeground: Bool = .mockAny(),
        appLaunchDate: Date? = .mockRandomInThePast(),
        lastRUMAttributes: RUMEventAttributes? = nil,
        lastLogAttributes: LogEventAttributes? = nil
    ) -> Self {
        .init(
            serverTimeOffset: serverTimeOffset,
            service: service,
            env: env,
            version: version,
            buildNumber: buildNumber,
            device: device,
            os: os,
            sdkVersion: service,
            source: source,
            trackingConsent: trackingConsent,
            userInfo: userInfo,
            accountInfo: accountInfo,
            networkConnectionInfo: networkConnectionInfo,
            carrierInfo: carrierInfo,
            lastIsAppInForeground: lastIsAppInForeground,
            appLaunchDate: appLaunchDate,
            lastRUMViewEvent: lastRUMViewEvent,
            lastRUMSessionState: lastRUMSessionState,
            lastRUMAttributes: lastRUMAttributes,
            lastLogAttributes: lastLogAttributes
        )
    }

    public static func mockRandom() -> Self {
        .init(
            serverTimeOffset: .zero,
            service: .mockRandom(),
            env: .mockRandom(),
            version: .mockRandom(),
            buildNumber: .mockRandom(),
            device: .mockRandom(),
            os: .mockRandom(),
            sdkVersion: .mockRandom(),
            source: .mockRandom(),
            trackingConsent: .granted,
            userInfo: .mockRandom(),
            accountInfo: .mockRandom(),
            networkConnectionInfo: .mockRandom(),
            carrierInfo: .mockRandom(),
            lastIsAppInForeground: .mockRandom(),
            appLaunchDate: .mockRandomInThePast(),
            lastRUMViewEvent: .mockRandom(),
            lastRUMSessionState: .mockRandom(),
            lastRUMAttributes: .mockRandom(),
            lastLogAttributes: .mockRandom()
        )
    }

    public var data: Data { try! JSONEncoder.dd.default().encode(self) }
}
