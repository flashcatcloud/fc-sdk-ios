/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation
import DatadogInternal

/// An object for sending crash reports.
internal protocol CrashReportSender {
    /// Send the crash report and context to integrations, and wait until they have processed it.
    ///
    /// - Parameters:
    ///   - report: The crash report.
    ///   - context: The crash context
    /// - Returns: what became of the crash: `.processed` once its events are written, or deliberately not produced, so
    ///   the crash report can be deleted; `.writeFailed` if writing them failed but may succeed later; `.kept` if it is
    ///   not known, so the report must be kept.
    func send(report: DDCrashReport, with context: CrashContext) -> CrashReportOutcome

    /// Send the launch report and context to integrations.
    ///
    /// - Parameters:
    ///   - launch: The launch report.
    func send(launch: LaunchReport)
}

/// An object for sending crash reports on the Core message-bus.
internal struct MessageBusSender: CrashReportSender {
    /// The core for sending crash report and context.
    ///
    /// It must be a weak reference to avoid retain cycle (the `CrashReportSender` is held by crash reporting
    /// integration kept by core).
    weak var core: DatadogCoreProtocol?

    /// How long `send(report:with:)` waits for the crash to be processed. Writing a crash takes milliseconds; reaching
    /// it means the SDK is stopping or blocked, and the report is kept for the next launch rather than risk losing it.
    var processingTimeout: TimeInterval = 10

    /// Send the crash report et context on the bus of the core, and wait until it is processed.
    ///
    /// - Parameters:
    ///   - report: The crash report.
    ///   - context: The crash context
    func send(report: DDCrashReport, with context: CrashContext) -> CrashReportOutcome {
        guard let core = core else {
            return .kept
        }

        let processed = DispatchSemaphore(value: 0)
        let result = ProcessingResult()
        core.send(
            message: .payload(
                Crash(report: report, context: context, completion: { result.outcome = $0; processed.signal() })
            ),
            else: {
                DD.logger.warn(
                    """
                    In order to use Crash Reporting, RUM feature must be enabled.
                    Make sure `RUM.enable(with:)` is called when initializing Datadog SDK.
                    The crash report is kept until it can be processed.
                    """
                )
                processed.signal()
            }
        )
        // `result` is written before `signal()` and read after `wait()` returns, which orders the two.
        return processed.wait(timeout: .now() + processingTimeout) == .success ? result.outcome : .kept
    }

    /// Send the launch report and context to integrations.
    ///
    /// - Parameters:
    ///   - launch: The launch report.
    func send(launch: DatadogInternal.LaunchReport) {
        core?.set(context: launch)
    }
}

private final class ProcessingResult {
    var outcome: CrashReportOutcome = .kept
}
