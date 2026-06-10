/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation
import DatadogInternal

/// Enable iOS Crash Reporting and Error Tracking to get comprehensive crash reports and
/// error trends with Real User Monitoring. With this feature, you can access:
///
/// - Aggregated iOS crash dashboards and attributes
/// - Symbolicated iOS crash reports
/// - Trend analysis with iOS error tracking
///
/// In order to symbolicate your stack traces, find and upload your .dSYM files to Datadog.
/// Then, verify your configuration by running a test crash and restarting your application.
///
/// Your crash reports appear in [Error Tracking](https://app.datadoghq.com/rum/error-tracking).
public final class CrashReporting {
    /// Crash Reporting configuration.
    public struct Configuration {
        /// Resolve crash stack frames to function/method names **on-device**, at crash time,
        /// using the symbols already present in the binary (no dSYM upload required).
        ///
        /// When `true` (default), crash reports contain readable function names even when no
        /// dSYM has been uploaded. When `false`, frames carry raw addresses only and rely on
        /// server-side symbolication with an uploaded dSYM.
        public var symbolicateInProcess: Bool

        /// Creates a Crash Reporting configuration.
        /// - Parameter symbolicateInProcess: see ``symbolicateInProcess``. Defaults to `true`.
        public init(symbolicateInProcess: Bool = true) {
            self.symbolicateInProcess = symbolicateInProcess
        }
    }

    /// Initializes the Datadog Crash Reporter using the default `KSCrash` plugin.
    /// - Parameters:
    ///   - configuration: Crash Reporting configuration (in-process symbolication is on by default).
    ///   - core: the SDK core instance.
    public static func enable(
        with configuration: Configuration = .init(),
        in core: DatadogCoreProtocol = CoreRegistry.default
    ) {
        enable(
            with: try KSCrashPlugin(telemetry: core.telemetry, symbolicateInProcess: configuration.symbolicateInProcess),
            in: core
        )
    }

    /// Initializes the Datadog Crash Reporter with a custom Crash Reporting Plugin.
    ///
    /// The custom plugin will be responsible for:
    /// - Provide crash report
    /// - Store context data associated with crashes
    /// - Provide backtraces
    public static func enable(with plugin: @autoclosure () throws -> CrashReportingPlugin, in core: DatadogCoreProtocol = CoreRegistry.default) {
        do {
            // To ensure the correct registration order between Core and Features,
            // the entire initialization flow is synchronized on the main thread.
            try runOnMainThreadSync {
                try enableOrThrow(with: plugin(), in: core)
            }
        } catch let error {
            consolePrint("\(error)", .error)
        }
    }

    internal static func enableOrThrow(with plugin: CrashReportingPlugin, in core: DatadogCoreProtocol) throws {
        guard !(core is NOPDatadogCore) else {
            throw ProgrammerError(
                description: "Datadog SDK must be initialized before calling `CrashReporting.enable()`."
            )
        }

        let contextProvider = CrashContextCoreProvider()

        let reporter = CrashReportingFeature(
            crashReportingPlugin: plugin,
            crashContextProvider: contextProvider,
            sender: MessageBusSender(core: core),
            messageReceiver: contextProvider,
            telemetry: core.telemetry
        )

        try core.register(feature: reporter)

        if let backtraceReporter = plugin.backtraceReporter {
            try core.register(backtraceReporter: backtraceReporter)
        }

        reporter.sendCrashReportIfFound()

        core.telemetry.configuration(trackErrors: true)
    }
}

/// Enable iOS Crash Reporting and Error Tracking to get comprehensive crash reports and
/// error trends with Real User Monitoring. With this feature, you can access:
///
/// - Aggregated iOS crash dashboards and attributes
/// - Symbolicated iOS crash reports
/// - Trend analysis with iOS error tracking
///
/// In order to symbolicate your stack traces, find and upload your .dSYM files to Datadog.
/// Then, verify your configuration by running a test crash and restarting your application.
///
/// Your crash reports appear in [Error Tracking](https://app.datadoghq.com/rum/error-tracking).
@available(swift, obsoleted: 1)
@objc(DDCrashReporter)
public final class objc_CrashReporting: NSObject {
    /// Initializes the Datadog Crash Reporter (in-process symbolication on by default).
    @objc
    public static func enable() {
        CrashReporting.enable()
    }

    /// Initializes the Datadog Crash Reporter.
    /// - Parameter symbolicateInProcess: resolve stack frames to function names on-device,
    ///   at crash time, without requiring a dSYM upload.
    @objc
    public static func enable(symbolicateInProcess: Bool) {
        CrashReporting.enable(with: .init(symbolicateInProcess: symbolicateInProcess))
    }
}
