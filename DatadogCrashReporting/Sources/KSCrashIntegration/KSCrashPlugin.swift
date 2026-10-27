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

    convenience init(
        _ kscrash: KSCrash = .shared,
        telemetry: Telemetry = NOPTelemetry(),
        symbolicateInProcess: Bool = true,
        handlesMachExceptions: Bool = false,
        takesOverCrashHandlers: Bool = false
    ) throws {
        do {
            let configuration = try KSCrashConfiguration.datadog(handlesMachExceptions: handlesMachExceptions)
            try kscrash.install(with: configuration)

            var filters: [CrashReportFilter] = [DatadogTypeSafeFilter()]
            if takesOverCrashHandlers, let installPath = configuration.installPath {
                let throwSiteFile = URL(fileURLWithPath: installPath).appendingPathComponent("cpp-throw-site.json")
                filters.append(DatadogCppThrowSiteFilter(throwSiteFile: throwSiteFile))
                if !CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile) {
                    telemetry.debug("[KSCrash] Crash handler takeover could not be activated")
                }
            }
            filters += [
                DatadogMinifyFilter(),
                DatadogDiagnosticFilter(),
                DatadogCrashReportFilter(telemetry: telemetry, symbolicateInProcess: symbolicateInProcess)
            ]
            kscrash.reportStore?.sink = CrashReportFilterPipeline(filters: filters)
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

        self.init(store: store, telemetry: telemetry)
    }

    /// - Parameter store: the report store to read reports from; its `sink` converts a KSCrash report into `DDCrashReport`.
    init(store: CrashReportStore, telemetry: Telemetry) {
        self.telemetry = telemetry
        self.store = store
        super.init()
    }

    // MARK: - CrashReportingPlugin

    func readPendingCrashReports(completion: @escaping ([DDCrashReport]) -> Bool) {
        let reportIDs = store.reportIDs.map { $0.int64Value } // sorted by ID, which grows with time: oldest first
        loadReports(with: reportIDs[...], loaded: []) { loaded in
            if completion(loaded.map { $0.report }) {
                loaded.forEach { self.store.deleteReport(with: $0.id) }
            }
        }
    }

    /// Loads the reports one at a time, so a report that cannot be loaded is purged without affecting the others.
    private func loadReports(
        with ids: ArraySlice<Int64>,
        loaded: [(id: Int64, report: DDCrashReport)],
        completion: @escaping ([(id: Int64, report: DDCrashReport)]) -> Void
    ) {
        guard let id = ids.first else {
            completion(loaded)
            return
        }

        loadReport(with: id) { report in
            self.loadReports(
                with: ids.dropFirst(),
                loaded: loaded + (report.map { [(id, $0)] } ?? []),
                completion: completion
            )
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
