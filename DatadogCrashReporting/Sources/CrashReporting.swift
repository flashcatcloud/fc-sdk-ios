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

        /// Also catch crashes through a Mach exception handler (`EXC_BAD_ACCESS`, `EXC_BAD_INSTRUCTION`,
        /// `EXC_BREAKPOINT`, ...), in addition to the signal handler.
        ///
        /// The kernel delivers a hardware exception to Mach exception handlers before it turns it into a signal,
        /// so crashes like segmentation faults and Swift runtime traps are recorded first, whichever signal handler
        /// another library (or crash reporter) has installed. Crashes raised as signals by the process itself
        /// (`abort()`, uncaught `NSException`, uncaught C++ exception) are not Mach exceptions and are unaffected.
        ///
        /// Disabled by default. Mach exception handling is not active while a debugger is attached.
        ///
        /// - Important: do not enable it in an app that recovers from hardware exceptions at runtime, for example
        ///   through a language runtime that turns invalid memory accesses into catchable errors (such as a Go core
        ///   built with gomobile, or Mono / .NET). The Mach handler sees such an exception before the runtime does:
        ///   it is recorded as a crash although the app keeps running, and crash reporting is turned off for the rest
        ///   of the process, so a later real crash is not recorded.
        public var handlesMachExceptions: Bool

        /// Keep the crash handlers in place once crash reporting is enabled: other code in the app (for example
        /// another crash reporter) can no longer replace or reset the crash signal handlers, the uncaught
        /// `NSException` handler or the C++ terminate handler; its attempts are recorded instead, and it is told
        /// that its handler is installed. Uncaught C++ exceptions are also reported with the stack of their throw
        /// site when the crash reporter could not capture it at throw time.
        ///
        /// Crash reporting still passes each crash on, once recorded, to the handler that was installed before it
        /// was enabled or, if another one was installed since, to that one: another crash reporter still receives
        /// crashes, after this one.
        ///
        /// Disabled by default. `SIGPIPE` is not affected.
        ///
        /// - Important: do not enable it in an app that installs its own handler for crash signals after crash
        ///   reporting is enabled and relies on it at runtime (for example a runtime that recovers from invalid
        ///   memory accesses): that handler is no longer installed.
        public var takesOverCrashHandlers: Bool

        /// Creates a Crash Reporting configuration.
        /// - Parameters:
        ///   - symbolicateInProcess: see ``symbolicateInProcess``. Defaults to `true`.
        ///   - handlesMachExceptions: see ``handlesMachExceptions``. Defaults to `false`.
        ///   - takesOverCrashHandlers: see ``takesOverCrashHandlers``. Defaults to `false`.
        public init(symbolicateInProcess: Bool = true, handlesMachExceptions: Bool = false, takesOverCrashHandlers: Bool = false) {
            self.symbolicateInProcess = symbolicateInProcess
            self.handlesMachExceptions = handlesMachExceptions
            self.takesOverCrashHandlers = takesOverCrashHandlers
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
            with: try KSCrashPlugin(
                telemetry: core.telemetry,
                symbolicateInProcess: configuration.symbolicateInProcess,
                handlesMachExceptions: configuration.handlesMachExceptions,
                takesOverCrashHandlers: configuration.takesOverCrashHandlers
            ),
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

    internal static func enableOrThrow(
        with plugin: CrashReportingPlugin,
        in core: DatadogCoreProtocol,
        processingDelay: TimeInterval = CrashReportingFeature.defaultProcessingDelay
    ) throws {
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
            telemetry: core.telemetry,
            processingDelay: processingDelay
        )

        // The crash context otherwise reaches the crash reporter through several asynchronous hops after the
        // Feature is registered, which can take seconds at launch: a crash in between was recorded without it and
        // then dropped. Write the first one now, before registering, so later updates always replace it. Skipped
        // when crash reporting is already enabled: this call fails to register and must not replace the live context.
        if core.get(feature: CrashReportingFeature.self) == nil, let context = core.currentContext() {
            reporter.inject(initialCrashContext: CrashContext(context, lastLogAttributes: nil))
        }

        try core.register(feature: reporter)

        if let backtraceReporter = plugin.backtraceReporter {
            try core.register(backtraceReporter: backtraceReporter)
        }

        reporter.start()

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

    /// Initializes the Datadog Crash Reporter.
    /// - Parameters:
    ///   - symbolicateInProcess: resolve stack frames to function names on-device,
    ///     at crash time, without requiring a dSYM upload.
    ///   - handlesMachExceptions: also catch crashes through a Mach exception handler,
    ///     see `CrashReporting.Configuration.handlesMachExceptions`.
    @objc
    public static func enable(symbolicateInProcess: Bool, handlesMachExceptions: Bool) {
        CrashReporting.enable(with: .init(symbolicateInProcess: symbolicateInProcess, handlesMachExceptions: handlesMachExceptions))
    }

    /// Initializes the Datadog Crash Reporter.
    /// - Parameters:
    ///   - symbolicateInProcess: resolve stack frames to function names on-device,
    ///     at crash time, without requiring a dSYM upload.
    ///   - handlesMachExceptions: also catch crashes through a Mach exception handler,
    ///     see `CrashReporting.Configuration.handlesMachExceptions`.
    ///   - takesOverCrashHandlers: keep the crash handlers in place once crash reporting is enabled,
    ///     see `CrashReporting.Configuration.takesOverCrashHandlers`.
    @objc
    public static func enable(symbolicateInProcess: Bool, handlesMachExceptions: Bool, takesOverCrashHandlers: Bool) {
        CrashReporting.enable(with: .init(
            symbolicateInProcess: symbolicateInProcess,
            handlesMachExceptions: handlesMachExceptions,
            takesOverCrashHandlers: takesOverCrashHandlers
        ))
    }
}
