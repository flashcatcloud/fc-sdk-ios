/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation
import DatadogInternal

/// An interface for enabling crash reporting feature in Datadog SDK.
///
/// The SDK calls each API on a background thread and succeeding calls are synchronized.
public protocol CrashReportingPlugin: AnyObject {
    /// Whether the previous run of the app ended with a crash.
    ///
    /// The SDK reads it once, as soon as crash reporting is enabled and before reading any report, to let other features
    /// know whether the previous process crashed (e.g. RUM, which otherwise reports an unexplained termination as a
    /// Watchdog Termination). It must not read crash reports: a crash while a report is being read can deadlock the
    /// crash handler, so reports are read only once the app has settled. Reports kept from earlier launches (see
    /// `readPendingCrashReports(process:)`) do not count.
    var crashedLastLaunch: Bool { get }

    /// How many launches in a row, before this one, found pending crash reports and ended before reading them (e.g.
    /// crash loops and processes ended by the system within seconds).
    ///
    /// The SDK reads it once, right after `crashedLastLaunch`. It is reset by `resetUnreadLaunches()` and by processing a
    /// pending report. Without a value, the SDK always waits for the app to settle before reading reports.
    var unreadLaunches: Int { get }

    /// Tells that this launch lasted until the SDK read the pending crash reports after waiting for the app to settle: it
    /// does not count as an unread launch, whatever becomes of the reports (e.g. kept while consent is pending).
    ///
    /// The SDK calls it once, right before that read.
    func resetUnreadLaunches()

    /// Reads the pending crash reports one at a time, oldest first.
    /// - Parameter process: called with each report in turn. It returns `.processed` once the report is processed and
    /// can be deleted, `.kept` to keep it for a later read, or `.writeFailed` to keep it for a limited number of reads.
    /// The next report is read only after `process` returns. A report that cannot be read is deleted without being
    /// passed to `process`.
    ///
    /// The SDK calls this method on a background thread. The implementation is free to choose any thread
    /// for executing `process`.
    func readPendingCrashReports(process: @escaping (DDCrashReport) -> CrashReportOutcome)

    /// Injects custom data for describing the application state in the crash report.
    /// This data will be attached to produced crash report and will be available in `DDCrashReport`.
    ///
    /// The SDK calls this method for each significant application state change.
    /// It is called on a background thread and succeeding calls are synchronized.
    func inject(context: Data)

    /// An instance conforming to `BacktraceReporting` capable of generating backtrace reports.
    var backtraceReporter: BacktraceReporting? { get }
}

extension CrashReportingPlugin {
    public var unreadLaunches: Int { 0 }
    public func resetUnreadLaunches() {}
}
