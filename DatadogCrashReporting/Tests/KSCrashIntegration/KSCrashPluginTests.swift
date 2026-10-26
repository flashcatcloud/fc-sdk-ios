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

    private func createPlugin() throws -> (KSCrashPlugin, CrashReportStore) {
        let configuration = CrashReportStoreConfiguration()
        configuration.reportsPath = reportsDirectory.path
        configuration.appName = appName
        configuration.reportCleanupPolicy = .never
        let store = try CrashReportStore(configuration: configuration)
        store.sink = MessageFieldFilter()
        return (KSCrashPlugin(store: store, telemetry: NOPTelemetry()), store)
    }

    func testItReadsEveryPendingReportOldestFirstAndDeletesThemOnceProcessed() throws {
        // Given
        try writeReport(id: 3, contents: #"{"message": "third"}"#)
        try writeReport(id: 1, contents: #"{"message": "first"}"#)
        try writeReport(id: 2, contents: #"{"message": "second"}"#)
        let (plugin, store) = try createPlugin()

        // When
        var readReports: [DDCrashReport]?
        plugin.readPendingCrashReports { reports in
            readReports = reports
            return true
        }

        // Then
        XCTAssertEqual(readReports?.map { $0.message }, ["first", "second", "third"])
        XCTAssertEqual(store.reportIDs, [], "It should delete every processed report")
    }

    func testItKeepsReportsWhenProcessingFails() throws {
        // Given
        try writeReport(id: 1, contents: #"{"message": "first"}"#)
        try writeReport(id: 2, contents: #"{"message": "second"}"#)
        let (plugin, store) = try createPlugin()

        // When
        plugin.readPendingCrashReports { _ in false }

        // Then
        XCTAssertEqual(store.reportIDs, [1, 2])
    }

    func testItPurgesReportsThatCannotBeLoadedWithoutDroppingOthers() throws {
        // Given
        try writeReport(id: 1, contents: #"{"message": "first"}"#)
        try writeReport(id: 2, contents: #"{"no message": true}"#) // rejected by the sink
        try writeReport(id: 3, contents: "not a JSON") // cannot be read
        try writeReport(id: 4, contents: #"{"message": "last"}"#)
        let (plugin, store) = try createPlugin()

        // When
        var readReports: [DDCrashReport]?
        plugin.readPendingCrashReports { reports in
            readReports = reports
            XCTAssertEqual(store.reportIDs, [1, 4], "It should purge unloadable reports before processing the others")
            return false
        }

        // Then
        XCTAssertEqual(readReports?.map { $0.message }, ["first", "last"])
        XCTAssertEqual(store.reportIDs, [1, 4], "It should keep the loaded reports when processing fails")
    }

    func testItReadsNoReportWhenStoreIsEmpty() throws {
        // Given
        let (plugin, _) = try createPlugin()

        // When
        var readReports: [DDCrashReport]?
        plugin.readPendingCrashReports { reports in
            readReports = reports
            return false
        }

        // Then
        XCTAssertEqual(readReports?.count, 0)
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
