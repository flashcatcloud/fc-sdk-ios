/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation

/// What became of a crash report given to the features that report crashes.
public enum CrashReportOutcome: Equatable {
    /// Its events are written, or it was decided not to write any (e.g. it is sampled out, or it can never be written):
    /// the report can be deleted.
    case processed
    /// It was not processed, e.g. as no feature receives crashes yet or consent is pending: the report is kept for a
    /// later read.
    case kept
    /// Writing its error failed in a way that may not happen again, e.g. as no file can be written to: the report is
    /// kept for a limited number of reads.
    case writeFailed
}

public struct Crash {
    /// The crash report.
    public let report: DDCrashReport
    /// The crash context
    public let context: CrashContext
    /// Called by the receiver once the crash is handled, with `.processed` when its error is written to storage or it
    /// decided not to produce one, and `.writeFailed` when the error could not be written but may be later. The crash
    /// report is deleted only after a `.processed` call, so a crash in between, or a failed write, does not lose it. A
    /// receiver that returns `false` from `receive(message:from:)` (not handled) does not call it.
    public let completion: (CrashReportOutcome) -> Void

    /// Creates a Crash to be transmited on the message-bus.
    ///
    /// - Parameters:
    ///   - report: The crash report.
    ///   - context: The crash context
    ///   - completion: Called by the receiver once the crash is processed.
    public init(report: DDCrashReport, context: CrashContext, completion: @escaping (CrashReportOutcome) -> Void = { _ in }) {
        self.report = report
        self.context = context
        self.completion = completion
    }
}
