/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation

// swiftlint:disable duplicate_imports
#if COCOAPODS
import KSCrash
#elseif swift(>=6.0)
internal import KSCrashRecording
#else
@_implementationOnly import KSCrashRecording
#endif
// swiftlint:enable duplicate_imports

/// A KSCrash filter that gives an uncaught C++ exception report the stack of its throw site, when the report has no
/// stack for the crashed thread and a throw site was recorded by the same process (see `ThrowSiteRecorder`).
///
/// It must run after `DatadogTypeSafeFilter` and before `DatadogMinifyFilter`, which keeps only the binary images
/// referenced by the backtraces.
internal final class DatadogCppThrowSiteFilter: NSObject, CrashReportFilter {
    /// A throw site recorded more than this before or after the crash belongs to another crash.
    static let maxTimeDifference: TimeInterval = 60

    private let throwSiteFile: URL

    init(throwSiteFile: URL) {
        self.throwSiteFile = throwSiteFile
        super.init()
    }

    func filterReports(
        _ reports: [CrashReport],
        onCompletion: (([CrashReport]?, (Error)?) -> Void)?
    ) {
        let throwSite = ThrowSiteRecorder.read(from: throwSiteFile)
        do {
            let reports = try reports.map { report -> CrashReport in
                guard let dict = report.untypedValue as? CrashFieldDictionary else {
                    throw CrashReportException(description: "KSCrash report untypedValue is not a CrashDictionary")
                }
                guard let throwSite, let filled = try fill(report: dict, with: throwSite) else {
                    return report
                }
                try? FileManager.default.removeItem(at: throwSiteFile)
                return AnyCrashReport(filled)
            }
            onCompletion?(reports, nil)
        } catch {
            onCompletion?(reports, error)
        }
    }

    /// Returns the report with the throw site as the crashed thread's stack, or `nil` if it does not apply.
    func fill(report: CrashFieldDictionary, with throwSite: ThrowSiteRecorder.ThrowSite) throws -> CrashFieldDictionary? {
        guard
            try report.valueIfPresent(String.self, forKey: .crash, .error, .type) == "cpp_exception",
            try report.valueIfPresent(Int64.self, forKey: .system, .processID) == throwSite.processID,
            let timestamp: String = try report.valueIfPresent(forKey: .report, .timestamp),
            let crashDate = Self.date(from: timestamp),
            abs(crashDate.timeIntervalSince(throwSite.date)) <= Self.maxTimeDifference,
            var threads: [CrashFieldDictionary] = try report.valueIfPresent(forKey: .crash, .threads),
            let crashedIndex = try threads.firstIndex(where: { try $0.valueIfPresent(Bool.self, forKey: .crashed) == true })
        else {
            return nil
        }

        let contents: [CrashFieldDictionary] = try threads[crashedIndex].valueIfPresent(forKey: .backtrace, .contents) ?? []
        guard contents.isEmpty, !throwSite.frames.isEmpty else {
            return nil // the crash reporter has a stack of its own
        }

        threads[crashedIndex].setValue(
            forKey: .backtrace,
            .contents,
            value: throwSite.frames.map { CrashFieldDictionary(from: $0) }
        )
        threads[crashedIndex].setValue(forKey: .backtrace, .skipped, value: 0)

        var filled = report
        filled.setValue(forKey: .crash, .threads, value: threads)
        return filled
    }

    private static func date(from timestamp: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: timestamp) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: timestamp)
    }
}
