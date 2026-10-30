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
        processingDelay: TimeInterval = 0,
        bundleVersion: String? = nil
    ) -> Self {
        .init(
            crashReportingPlugin: crashReportingPlugin,
            crashContextProvider: crashContextProvider,
            sender: integration,
            messageReceiver: messageReceiver,
            telemetry: telemetry,
            processingDelay: processingDelay,
            bundleVersion: bundleVersion
        )
    }
}

public class CrashReportingPluginMock: CrashReportingPlugin {
    /// The value of `crashedLastLaunch`.
    public var crashedLastLaunch = false
    /// The value of `unreadLaunches`.
    public var unreadLaunches = 0
    /// How many times `resetUnreadLaunches()` was called.
    @ReadWriteLock
    public var resetUnreadLaunchesCount = 0
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

    public func resetUnreadLaunches() {
        resetUnreadLaunchesCount += 1
    }

    public func readPendingCrashReports(process: (DDCrashReport) -> CrashReportOutcome) {
        readCount += 1
        var kept: [DDCrashReport] = []
        for report in pendingCrashReports {
            if process(report) == .processed {
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
    public func readPendingCrashReports(process: (DDCrashReport) -> CrashReportOutcome) {}
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
    /// What `send(report:with:)` returns.
    public var crashReportOutcome: CrashReportOutcome = .processed

    public init() {}

    public func send(report: DDCrashReport, with context: CrashContext) -> CrashReportOutcome {
        sentCrashReports.append((report, context))
        didSendCrashReport?()
        return crashReportOutcome
    }

    public var didSendCrashReport: (() -> Void)?

    public func send(launch: DatadogInternal.LaunchReport) {
        sentLaunchReports.append(launch)
    }
}

public class CrashReceiverMock: FeatureMessageReceiver {
    public var receivedCrash: Crash?
    /// What the receiver reports through the crash completion.
    public var outcome: CrashReportOutcome = .processed

    public func receive(message: FeatureMessage, from core: DatadogCoreProtocol) -> Bool {
        guard case let .payload(crash as Crash) = message else {
            return false
        }
        receivedCrash = crash
        crash.completion(outcome)
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

/// A `sigaction` wrapper of the kind another library installs by rewriting symbol pointers: it counts the calls and
/// passes them to the real function. It lives in this framework, an image of its own.
public enum SigactionWrapperMock {
    public typealias Function = @convention(c) (Int32, UnsafePointer<sigaction>?, UnsafeMutablePointer<sigaction>?) -> Int32

    public static var calls = 0

    public static let function: Function = { signal, action, oldAction in
        calls += 1
        return real(signal, action, oldAction)
    }

    private static let real = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sigaction"), to: Function.self)
}
