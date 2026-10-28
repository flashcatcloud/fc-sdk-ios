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
    /// Holds the IDs of the reports found at the previous launch, one per line.
    private let knownReportIDsFile: URL
    /// Held the ID of the most recent report found at the previous launch, before `knownReportIDsFile` replaced it.
    private let legacyLatestReportIDFile: URL
    /// Holds `unreadLaunches`, counting this launch while its reports are not read.
    private let unreadLaunchesFile: URL
    /// Holds how many times the error of each report could not be written, one "<report ID> <count>" per line.
    private let writeAttemptsFile: URL

    /// After this many reads whose error could not be written, a report is deleted: the failure is not passing.
    static let maxWriteAttempts = 3

    /// A report that was not there at the previous launch was written by the previous process.
    ///
    /// It is decided by comparing the report IDs with the ones recorded at the previous launch, without reading any
    /// report (listing the IDs is what KSCrash already does when it is installed). Report IDs derive from the clock,
    /// which can move backwards, so they are compared as a set and not by order. The presence of reports alone is not
    /// enough: a report can be kept across launches, e.g. until tracking consent is resolved. KSCrash's own
    /// `crashedLastLaunch` needs its application state monitor, which this plugin does not install.
    ///
    /// Computed once, on first access (from the Feature queue), before any report is deleted.
    private(set) lazy var crashedLastLaunch: Bool = {
        let reportIDs = Set(store.reportIDs.map { $0.int64Value })
        let crashed = !reportIDs.subtracting(knownReportIDs(among: reportIDs)).isEmpty
        do {
            let contents = reportIDs.sorted().map(String.init).joined(separator: "\n")
            try contents.write(to: knownReportIDsFile, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: legacyLatestReportIDFile)
        } catch {
            telemetry.error("[KSCrash] Fails to record the known report IDs", error: error)
        }
        return crashed
    }()

    /// Computed once, on first access (from the Feature queue), before any report is read. This launch is counted as one
    /// more unread launch until a pending report is processed (`process` returns `.processed`): a read that processes none,
    /// e.g. as no feature receives crashes yet, does not count.
    private(set) lazy var unreadLaunches: Int = {
        let unreadLaunches = (try? String(contentsOf: unreadLaunchesFile, encoding: .utf8)).flatMap { Int($0) } ?? 0
        recordUnreadLaunches(store.reportIDs.isEmpty ? 0 : unreadLaunches + 1)
        return unreadLaunches
    }()

    private func recordUnreadLaunches(_ count: Int) {
        do {
            try String(count).write(to: unreadLaunchesFile, atomically: true, encoding: .utf8)
        } catch {
            telemetry.error("[KSCrash] Fails to record the unread launches", error: error)
        }
    }

    /// The report IDs recorded at the previous launch. After an upgrade, only the most recent one was recorded: the
    /// reports up to it count as known, this once.
    private func knownReportIDs(among reportIDs: Set<Int64>) -> Set<Int64> {
        if let contents = try? String(contentsOf: knownReportIDsFile, encoding: .utf8) {
            return Set(contents.split(separator: "\n").compactMap { Int64($0) })
        }
        guard let latestReportID = (try? String(contentsOf: legacyLatestReportIDFile, encoding: .utf8)).flatMap({ Int64($0) }) else {
            return []
        }
        return reportIDs.filter { $0 <= latestReportID }
    }

    convenience init(
        _ kscrash: KSCrash = .shared,
        telemetry: Telemetry = NOPTelemetry(),
        symbolicateInProcess: Bool = true,
        handlesMachExceptions: Bool = false,
        takesOverCrashHandlers: Bool = false
    ) throws {
        let configuration = try KSCrashConfiguration.datadog(handlesMachExceptions: handlesMachExceptions)
        let exceptionHandlerBeforeInstall = NSGetUncaughtExceptionHandler().map { unsafeBitCast($0, to: UnsafeMutableRawPointer.self) }
        do {
            // The crash reporter starts its Mach exception threads while it is installed.
            let threadsBeforeInstall = handlesMachExceptions ? CrashHandlerTakeover.taskThreads() : []
            try kscrash.install(with: configuration)
            let threadsStartedByInstall = handlesMachExceptions
                ? CrashHandlerTakeover.taskThreads().filter { !threadsBeforeInstall.contains($0) }
                : nil

            var filters: [CrashReportFilter] = [DatadogTypeSafeFilter()]
            if takesOverCrashHandlers, let sanitizer = CrashHandlerTakeover.sanitizer() {
                consolePrint("DatadogCrashReporting: crash handler takeover is disabled under \(sanitizer)", .warn)
                telemetry.debug("[KSCrash] Crash handler takeover skipped under \(sanitizer)")
            } else if takesOverCrashHandlers, let installPath = configuration.installPath {
                let throwSiteFile = URL(fileURLWithPath: installPath).appendingPathComponent("cpp-throw-site")
                filters.append(DatadogCppThrowSiteFilter(throwSiteFile: throwSiteFile))
                if !CrashHandlerTakeover.activate(
                    throwSiteFile: throwSiteFile,
                    threadsStartedByCrashReporter: threadsStartedByInstall,
                    exceptionHandlerBeforeCrashReporter: exceptionHandlerBeforeInstall
                ) {
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

        guard let installPath = configuration.installPath else {
            throw CrashReportException(description: "[KSCrash] Install path should be set")
        }

        self.init(store: store, stateDirectory: URL(fileURLWithPath: installPath), telemetry: telemetry)
    }

    /// - Parameters:
    ///   - store: the report store to read reports from; its `sink` converts a KSCrash report into `DDCrashReport`.
    ///   - stateDirectory: the directory of the files recording what was found at the previous launch, see `crashedLastLaunch`.
    init(store: CrashReportStore, stateDirectory: URL, telemetry: Telemetry) {
        self.telemetry = telemetry
        self.store = store
        self.knownReportIDsFile = stateDirectory.appendingPathComponent("known-report-ids")
        self.legacyLatestReportIDFile = stateDirectory.appendingPathComponent("latest-report-id")
        self.unreadLaunchesFile = stateDirectory.appendingPathComponent("unread-launches")
        self.writeAttemptsFile = stateDirectory.appendingPathComponent("write-attempts")
        super.init()
    }

    // MARK: - CrashReportingPlugin

    /// Whether the takeover's handlers were checked in this process.
    private var checkedHandlerTakeover = false
    /// Whether a pending report was processed in this process, which resets `unreadLaunches`.
    private var processedReportThisLaunch = false
    /// How many times the error of each pending report could not be written, while reports are read.
    private var writeAttempts: [Int64: Int] = [:]

    func readPendingCrashReports(process: @escaping (DDCrashReport) -> CrashReportOutcome) {
        if !checkedHandlerTakeover {
            checkedHandlerTakeover = true
            let displaced = CrashHandlerTakeover.displacedHandlers()
            if !displaced.isEmpty {
                telemetry.debug("[KSCrash] Crash handlers were displaced", attributes: ["displaced": displaced.joined(separator: ", ")])
            }
        }
        _ = unreadLaunches // counts this launch first, if it was not
        let reportIDs = store.reportIDs.map { $0.int64Value } // sorted by ID, which grows with time: oldest first
        writeAttempts = readWriteAttempts().filter { reportIDs.contains($0.key) }
        readReports(with: reportIDs[...], process: process)
    }

    /// Reads, processes and deletes the reports one at a time: a report is deleted only once it is processed, and a
    /// report that cannot be loaded is purged without affecting the others.
    /// A report whose error could not be written is kept until `maxWriteAttempts` reads failed so.
    private func readReports(with ids: ArraySlice<Int64>, process: @escaping (DDCrashReport) -> CrashReportOutcome) {
        guard let id = ids.first else {
            recordWriteAttempts(writeAttempts)
            return
        }

        loadReport(with: id) { report in
            if let report = report {
                self.handle(process(report), ofReportWith: id)
            } else {
                self.writeAttempts[id] = nil // purged
            }
            self.readReports(with: ids.dropFirst(), process: process)
        }
    }

    private func handle(_ outcome: CrashReportOutcome, ofReportWith id: Int64) {
        switch outcome {
        case .processed:
            store.deleteReport(with: id)
            writeAttempts[id] = nil
            if !processedReportThisLaunch {
                processedReportThisLaunch = true
                recordUnreadLaunches(0)
            }
        case .kept:
            break
        case .writeFailed:
            let attempts = (writeAttempts[id] ?? 0) + 1
            if attempts < Self.maxWriteAttempts {
                writeAttempts[id] = attempts
            } else {
                store.deleteReport(with: id)
                writeAttempts[id] = nil
                telemetry.error("[KSCrash] Deleted a crash report whose error could not be written \(attempts) times")
            }
        }
    }

    private func readWriteAttempts() -> [Int64: Int] {
        guard let contents = try? String(contentsOf: writeAttemptsFile, encoding: .utf8) else {
            return [:]
        }
        var attempts: [Int64: Int] = [:]
        for line in contents.split(separator: "\n") {
            let fields = line.split(separator: " ")
            if fields.count == 2, let id = Int64(fields[0]), let count = Int(fields[1]) {
                attempts[id] = count
            }
        }
        return attempts
    }

    private func recordWriteAttempts(_ attempts: [Int64: Int]) {
        guard !attempts.isEmpty else {
            try? FileManager.default.removeItem(at: writeAttemptsFile)
            return
        }
        do {
            let contents = attempts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "\n")
            try contents.write(to: writeAttemptsFile, atomically: true, encoding: .utf8)
        } catch {
            telemetry.error("[KSCrash] Fails to record the write attempts", error: error)
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
