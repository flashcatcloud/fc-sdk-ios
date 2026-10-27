/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation
import DatadogInternal

// swiftlint:disable duplicate_imports
#if COCOAPODS
import KSCrash
#elseif swift(>=6.0)
internal import KSCrashRecording
internal import KSCrashFilters
#else
@_implementationOnly import KSCrashRecording
@_implementationOnly import KSCrashFilters
#endif
// swiftlint:enable duplicate_imports

/// The implementation of `CrashReportingPlugin`.
/// Pass its instance as the crash reporting plugin for Datadog SDK to enable crash reporting feature.
@objc
internal class KSCrashPlugin: NSObject, CrashReportingPlugin {
    private let store: CrashReportStore
    private let telemetry: Telemetry
    /// Holds the ID of the most recent report found at the previous launch.
    private let latestReportIDFile: URL

    /// A report more recent than the most recent one found at the previous launch was written by the previous process.
    ///
    /// It is decided from the report IDs, which grow with time, and the ID recorded at the previous launch, without
    /// reading any report (listing the IDs is what KSCrash already does when it is installed). The presence of reports
    /// alone is not enough: a report can be kept across launches, e.g. until tracking consent is resolved. KSCrash's own
    /// `crashedLastLaunch` needs its application state monitor, which this plugin does not install.
    ///
    /// Computed once, on first access (from the Feature queue), before any report is deleted.
    private(set) lazy var crashedLastLaunch: Bool = {
        let latestReportID = store.reportIDs.last?.int64Value ?? 0 // sorted by ID: the last one is the most recent
        let knownReportID = (try? String(contentsOf: latestReportIDFile, encoding: .utf8)).flatMap { Int64($0) } ?? 0
        guard latestReportID > knownReportID else {
            return false
        }
        do {
            try String(latestReportID).write(to: latestReportIDFile, atomically: true, encoding: .utf8)
        } catch {
            telemetry.error("[KSCrash] Fails to record the latest report ID", error: error)
        }
        return true
    }()

    convenience init(
        _ kscrash: KSCrash = .shared,
        telemetry: Telemetry = NOPTelemetry(),
        symbolicateInProcess: Bool = true,
        handlesMachExceptions: Bool = false
    ) throws {
        let configuration = try KSCrashConfiguration.datadog(handlesMachExceptions: handlesMachExceptions)
        do {
            try kscrash.install(with: configuration)
            kscrash.reportStore?.sink = CrashReportFilterPipeline(
                filters: [
                    DatadogTypeSafeFilter(),
                    DatadogMinifyFilter(),
                    DatadogDiagnosticFilter(),
                    DatadogCrashReportFilter(telemetry: telemetry, symbolicateInProcess: symbolicateInProcess)
                ]
            )
        } catch KSCrashInstallError.alreadyInstalled {
            consolePrint("DatadogCrashReporting error: crash reporting is already installed", .warn)
            telemetry.debug("[KSCrash] already installed")
        } catch {
            telemetry.error("[KSCrash] Fails installation", error: error)
            throw error
        }

        guard let store = kscrash.reportStore else {
            throw CrashReportException(description: "[KSCrash] Report store should exist after installation")
        }

        guard let installPath = configuration.installPath else {
            throw CrashReportException(description: "[KSCrash] Install path should be set")
        }

        self.init(
            store: store,
            latestReportIDFile: URL(fileURLWithPath: installPath).appendingPathComponent("latest-report-id"),
            telemetry: telemetry
        )
    }

    /// - Parameters:
    ///   - store: the report store to read reports from; its `sink` converts a KSCrash report into `DDCrashReport`.
    ///   - latestReportIDFile: the file recording the most recent report ID found at launch, see `crashedLastLaunch`.
    init(store: CrashReportStore, latestReportIDFile: URL, telemetry: Telemetry) {
        self.telemetry = telemetry
        self.store = store
        self.latestReportIDFile = latestReportIDFile
        super.init()
    }

    // MARK: - CrashReportingPlugin

    func readPendingCrashReports(process: @escaping (DDCrashReport) -> Bool) {
        let reportIDs = store.reportIDs.map { $0.int64Value } // sorted by ID, which grows with time: oldest first
        readReports(with: reportIDs[...], process: process)
    }

    /// Reads, processes and deletes the reports one at a time: a report is deleted only once it is processed, and a
    /// report that cannot be loaded is purged without affecting the others.
    private func readReports(with ids: ArraySlice<Int64>, process: @escaping (DDCrashReport) -> Bool) {
        guard let id = ids.first else {
            return
        }

        loadReport(with: id) { report in
            if let report = report, process(report) {
                self.store.deleteReport(with: id)
            }
            self.readReports(with: ids.dropFirst(), process: process)
        }
    }

    /// Reads the report with given ID and converts it through the store's `sink`.
    /// Calls `completion` with `nil` after purging the report if it cannot be read or converted.
    private func loadReport(with id: Int64, completion: @escaping (DDCrashReport?) -> Void) {
        let purge = { (error: Error) in
            self.store.deleteReport(with: id)
            consolePrint("🔥 DatadogCrashReporting error: failed to load crash report: \(error)", .error)
            self.telemetry.error("[KSCrash] Fails to load crash report", error: error)
            completion(nil)
        }

        guard let sink = store.sink else {
            purge(CrashReportException(description: "Report store has no sink"))
            return
        }
        guard let report = store.report(for: id) else {
            purge(CrashReportException(description: "Report cannot be read"))
            return
        }

        sink.filterReports([report]) { reports, error in
            if let error {
                purge(error)
            } else if let report = reports?.first?.untypedValue as? DDCrashReport {
                completion(report)
            } else {
                purge(CrashReportException(description: "Report is not of type DDCrashReport"))
            }
        }
    }

    func inject(context: Data) {
        // `kscrash_setUserInfoJSON` expects a NUL-terminated C string, which raw `Data` bytes are not.
        let contextString = String(decoding: context, as: UTF8.self)
        contextString.withCString {
            kscrash_setUserInfoJSON($0)
        }
    }

    var backtraceReporter: BacktraceReporting? { KSCrashBacktrace(telemetry: telemetry) }
}

extension KSCrashConfiguration {
    static func datadog(handlesMachExceptions: Bool = false) throws -> KSCrashConfiguration {
        let version = "v2"

        guard let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw CrashReportException(description: "Cannot obtain `/Library/Caches/` url.")
        }

        let directory = cache.appendingPathComponent("com.datadoghq.crash-reporting/\(version)", isDirectory: true)

        let config = KSCrashConfiguration()
        config.installPath = directory.path
        // `.machException` is opt-in. The choice of `.BSD` (.signal) over `.mach` is well discussed here:
        // https://github.com/microsoft/PLCrashReporter/blob/7f27b272d5ff0d6650fc41317127bb2378ed6e88/Source/CrashReporter.h#L238-L363
        config.monitors = [.signal, .cppException, .nsException, .system]
        if handlesMachExceptions {
            config.monitors.insert(.machException)
        }
        // Keep rebinding `__cxa_throw` (the KSCrash default), which records the throw site of C++ exceptions.
        // dd-sdk-ios 3.6.1 disables it, but with KSCrash 2.5.x an uncaught C++ exception on the thread that
        // installed crash reporting is then reported with an empty stack.
        config.enableSwapCxaThrow = true
        // Keep several reports, so crashes recorded before the previous ones were sent (e.g. a crash loop at launch) are
        // not lost. KSCrash keeps the most recent ones. The value matches the KSCrash default: it bounds disk use and
        // what a crash loop sends, as the reports it produces are mostly identical.
        config.reportStoreConfiguration.maxReportCount = 5
        config.reportStoreConfiguration.reportCleanupPolicy = .never
        return config
    }
}
