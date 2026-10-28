/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation

public struct Crash {
    /// The crash report.
    public let report: DDCrashReport
    /// The crash context
    public let context: CrashContext
    /// Called by the receiver once the crash is processed, with `true` when the events it produces are written to
    /// storage or it decided not to produce any, and `false` when they could not be written. The crash report is
    /// deleted only after a `true` call, so a crash in between, or a failed write, does not lose it. A receiver that
    /// returns `false` from `receive(message:from:)` (not handled) does not call it.
    public let completion: (_ processed: Bool) -> Void

    /// Creates a Crash to be transmited on the message-bus.
    ///
    /// - Parameters:
    ///   - report: The crash report.
    ///   - context: The crash context
    ///   - completion: Called by the receiver once the crash is processed.
    public init(report: DDCrashReport, context: CrashContext, completion: @escaping (_ processed: Bool) -> Void = { _ in }) {
        self.report = report
        self.context = context
        self.completion = completion
    }
}
