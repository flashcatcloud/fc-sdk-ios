/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import XCTest
import TestUtilities
import DatadogInternal
@testable import DatadogCrashReporting
import KSCrashRecording

class KSCrashPluginTests: XCTestCase {
    // MARK: - Configuration Tests

    func testConfiguration() throws {
        // When
        let config: KSCrashConfiguration = try .datadog()

        // Then
        XCTAssertTrue(config.installPath?.contains("/Library/Caches/com.datadoghq.crash-reporting/v2") ?? false)
        XCTAssertEqual(config.reportStoreConfiguration.maxReportCount, 5)
        XCTAssertEqual(config.reportStoreConfiguration.reportCleanupPolicy, .never)
        XCTAssertTrue(config.enableSwapCxaThrow)
        XCTAssertEqual(config.monitors, [.signal, .cppException, .nsException, .system])
    }

    func testConfigurationWithMachExceptionHandling() throws {
        // When
        let config: KSCrashConfiguration = try .datadog(handlesMachExceptions: true)

        // Then
        XCTAssertEqual(config.monitors, [.signal, .cppException, .nsException, .system, .machException])
    }

    // MARK: - Reading Pending Reports Tests

    private let appName = "test"
    private var reportsDirectory: URL! // swiftlint:disable:this implicitly_unwrapped_optional

    override func setUpWithError() throws {
        try super.setUpWithError()
        reportsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KSCrashPluginTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: reportsDirectory)
        try super.tearDownWithError()
    }

    /// Writes a report file the way KSCrash names it, so the store lists it under `id`.
    private func writeReport(id: Int64, contents: String) throws {
        let fileName = String(format: "%@-report-%016llx.json", appName, id)
        try contents.write(to: reportsDirectory.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
    }

    private var latestReportIDFile: URL { reportsDirectory.appendingPathComponent("latest-report-id") }

    private func createPlugin() throws -> (KSCrashPlugin, CrashReportStore) {
        let configuration = CrashReportStoreConfiguration()
        configuration.reportsPath = reportsDirectory.path
        configuration.appName = appName
        configuration.reportCleanupPolicy = .never
        let store = try CrashReportStore(configuration: configuration)
        store.sink = MessageFieldFilter()
        return (KSCrashPlugin(store: store, latestReportIDFile: latestReportIDFile, telemetry: NOPTelemetry()), store)
    }

    func testItReadsEveryPendingReportOldestFirstAndDeletesEachOneOnceProcessed() throws {
        // Given
        try writeReport(id: 3, contents: #"{"message": "third"}"#)
        try writeReport(id: 1, contents: #"{"message": "first"}"#)
        try writeReport(id: 2, contents: #"{"message": "second"}"#)
        let (plugin, store) = try createPlugin()

        // When
        var processed: [String] = []
        var storeWhileProcessing: [[NSNumber]] = []
        plugin.readPendingCrashReports { report in
            processed.append(report.message)
            storeWhileProcessing.append(store.reportIDs)
            return true
        }

        // Then
        XCTAssertEqual(processed, ["first", "second", "third"])
        XCTAssertEqual(
            storeWhileProcessing,
            [[1, 2, 3], [2, 3], [3]],
            "Each report must stay on disk until it is processed, and be deleted before the next one is read"
        )
        XCTAssertEqual(store.reportIDs, [], "It should delete every processed report")
    }

    func testItKeepsTheReportsThatAreNotProcessed() throws {
        // Given
        try writeReport(id: 1, contents: #"{"message": "first"}"#)
        try writeReport(id: 2, contents: #"{"message": "second"}"#)
        try writeReport(id: 3, contents: #"{"message": "third"}"#)
        let (plugin, store) = try createPlugin()

        // When
        plugin.readPendingCrashReports { report in report.message != "second" }

        // Then
        XCTAssertEqual(store.reportIDs, [2])
    }

    func testItPurgesReportsThatCannotBeLoadedWithoutDroppingOthers() throws {
        // Given
        try writeReport(id: 1, contents: #"{"message": "first"}"#)
        try writeReport(id: 2, contents: #"{"no message": true}"#) // rejected by the sink
        try writeReport(id: 3, contents: "not a JSON") // cannot be read
        try writeReport(id: 4, contents: #"{"message": "last"}"#)
        let (plugin, store) = try createPlugin()

        // When
        var processed: [String] = []
        plugin.readPendingCrashReports { report in
            processed.append(report.message)
            return false
        }

        // Then
        XCTAssertEqual(processed, ["first", "last"])
        XCTAssertEqual(store.reportIDs, [1, 4], "It should purge unloadable reports and keep the ones not processed")
    }

    func testItReadsNoReportWhenStoreIsEmpty() throws {
        // Given
        let (plugin, _) = try createPlugin()

        // When
        var processCount = 0
        plugin.readPendingCrashReports { _ in
            processCount += 1
            return true
        }

        // Then
        XCTAssertEqual(processCount, 0)
    }

    // MARK: - Crashed Last Launch Tests

    func testWhenThereIsNoReport_theLastLaunchDidNotCrash() throws {
        let (plugin, _) = try createPlugin()
        XCTAssertFalse(plugin.crashedLastLaunch)
    }

    func testWhenAReportIsFoundForTheFirstTime_theLastLaunchCrashed() throws {
        // Given
        try writeReport(id: 1, contents: #"{"message": "first"}"#)
        try writeReport(id: 2, contents: #"{"message": "second"}"#)

        // When
        let (plugin, _) = try createPlugin()

        // Then
        XCTAssertTrue(plugin.crashedLastLaunch)
        XCTAssertEqual(try String(contentsOf: latestReportIDFile, encoding: .utf8), "2", "It records the most recent report ID")
    }

    func testWhenOnlyReportsFoundAtAnEarlierLaunchRemain_theLastLaunchDidNotCrash() throws {
        // Given (e.g. a report kept until tracking consent is resolved)
        try writeReport(id: 1, contents: #"{"message": "kept"}"#)
        XCTAssertTrue(try createPlugin().0.crashedLastLaunch, "Launch that found the report")

        // When
        let (plugin, _) = try createPlugin()

        // Then
        XCTAssertFalse(plugin.crashedLastLaunch, "The report was written before the last launch")
    }

    func testWhenANewerReportIsFound_theLastLaunchCrashed() throws {
        // Given
        try writeReport(id: 1, contents: #"{"message": "kept"}"#)
        XCTAssertTrue(try createPlugin().0.crashedLastLaunch)
        try writeReport(id: 2, contents: #"{"message": "new"}"#)

        // When
        let (plugin, _) = try createPlugin()

        // Then
        XCTAssertTrue(plugin.crashedLastLaunch)
    }

    func testWhenReportsWereDeleted_theLastLaunchDidNotCrash() throws {
        // Given
        try writeReport(id: 5, contents: #"{"message": "processed"}"#)
        XCTAssertTrue(try createPlugin().0.crashedLastLaunch)
        let (processing, store) = try createPlugin()
        processing.readPendingCrashReports { _ in true }
        XCTAssertEqual(store.reportIDs, [])

        // When
        let (plugin, _) = try createPlugin()

        // Then
        XCTAssertFalse(plugin.crashedLastLaunch)
    }
}

/// Converts a report into `DDCrashReport` carrying the report's `message` field, and fails for a report without one.
private final class MessageFieldFilter: NSObject, CrashReportFilter {
    func filterReports(_ reports: [CrashReport], onCompletion: (([CrashReport]?, Error?) -> Void)?) {
        do {
            let converted = try reports.map { report -> CrashReport in
                guard let message = (report as? CrashReportDictionary)?.value["message"] as? String else {
                    throw ErrorMock("report has no message")
                }
                return AnyCrashReport(DDCrashReport.mockWith(message: message))
            }
            onCompletion?(converted, nil)
        } catch {
            onCompletion?(reports, error)
        }
    }
}
