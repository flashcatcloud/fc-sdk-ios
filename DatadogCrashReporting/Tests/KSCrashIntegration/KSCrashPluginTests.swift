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

    private var knownReportIDsFile: URL { reportsDirectory.appendingPathComponent("known-report-ids") }
    private var legacyLatestReportIDFile: URL { reportsDirectory.appendingPathComponent("latest-report-id") }

    private func createPlugin(telemetry: Telemetry = NOPTelemetry()) throws -> (KSCrashPlugin, CrashReportStore) {
        let configuration = CrashReportStoreConfiguration()
        configuration.reportsPath = reportsDirectory.path
        configuration.appName = appName
        configuration.reportCleanupPolicy = .never
        let store = try CrashReportStore(configuration: configuration)
        store.sink = MessageFieldFilter()
        return (KSCrashPlugin(store: store, stateDirectory: reportsDirectory, telemetry: telemetry), store)
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
            return .processed
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
        plugin.readPendingCrashReports { report in report.message != "second" ? .processed : .kept }

        // Then
        XCTAssertEqual(store.reportIDs, [2])
    }

    func testWhenTheErrorOfAReportCannotBeWritten_itIsDeletedAfterThreeReads() throws {
        // Given
        try writeReport(id: 1, contents: #"{"message": "unwritable"}"#)
        try writeReport(id: 2, contents: #"{"message": "kept"}"#)
        let telemetry = TelemetryMock()

        // When (one read per launch)
        var reportIDsAfterEachRead: [[NSNumber]] = []
        for _ in 0..<3 {
            let (plugin, store) = try createPlugin(telemetry: telemetry)
            plugin.readPendingCrashReports { $0.message == "unwritable" ? .writeFailed : .kept }
            reportIDsAfterEachRead.append(store.reportIDs)
        }

        // Then
        XCTAssertEqual(reportIDsAfterEachRead, [[1, 2], [1, 2], [2]])
        XCTAssertEqual(telemetry.messages.firstError()?.message, "[KSCrash] Deleted a crash report whose error could not be written 3 times")
    }

    func testWhenAReportIsProcessedAfterAFailedWrite_itsAttemptsAreForgotten() throws {
        // Given
        try writeReport(id: 1, contents: #"{"message": "first"}"#)
        try createPlugin().0.readPendingCrashReports { _ in .writeFailed }
        try createPlugin().0.readPendingCrashReports { _ in .writeFailed }

        // When
        try createPlugin().0.readPendingCrashReports { _ in .processed }

        // Then
        XCTAssertFalse(FileManager.default.fileExists(atPath: reportsDirectory.appendingPathComponent("write-attempts").path))
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
            return .kept
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
            return .processed
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
        XCTAssertEqual(try String(contentsOf: knownReportIDsFile, encoding: .utf8), "1\n2", "It records every report ID")
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

    func testWhenANewReportHasALowerIDThanTheKnownOnes_theLastLaunchCrashed() throws {
        // Given (the clock moved backwards between the two crashes)
        try writeReport(id: 5, contents: #"{"message": "kept"}"#)
        XCTAssertTrue(try createPlugin().0.crashedLastLaunch)
        try writeReport(id: 3, contents: #"{"message": "new"}"#)

        // When
        let (plugin, _) = try createPlugin()

        // Then
        XCTAssertTrue(plugin.crashedLastLaunch)
    }

    func testGivenTheLatestReportIDOfAnEarlierVersion_itCountsReportsUpToItAsKnown() throws {
        // Given
        try writeReport(id: 1, contents: #"{"message": "kept"}"#)
        try writeReport(id: 2, contents: #"{"message": "kept"}"#)
        try "2".write(to: legacyLatestReportIDFile, atomically: true, encoding: .utf8)

        // When
        let (plugin, _) = try createPlugin()

        // Then
        XCTAssertFalse(plugin.crashedLastLaunch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyLatestReportIDFile.path), "The earlier file is replaced")
        XCTAssertEqual(try String(contentsOf: knownReportIDsFile, encoding: .utf8), "1\n2")
    }

    func testGivenTheLatestReportIDOfAnEarlierVersion_whenANewerReportIsFound_theLastLaunchCrashed() throws {
        // Given
        try writeReport(id: 2, contents: #"{"message": "kept"}"#)
        try writeReport(id: 3, contents: #"{"message": "new"}"#)
        try "2".write(to: legacyLatestReportIDFile, atomically: true, encoding: .utf8)

        // When
        let (plugin, _) = try createPlugin()

        // Then
        XCTAssertTrue(plugin.crashedLastLaunch)
    }

    // MARK: - Unread Launches Tests

    func testItCountsTheLaunchesInARowThatEndedBeforeReadingThePendingReports() throws {
        // Given
        try writeReport(id: 1, contents: #"{"message": "pending"}"#)

        // When
        let counts = try (0..<3).map { _ in try createPlugin().0.unreadLaunches }

        // Then
        XCTAssertEqual(counts, [0, 1, 2])
    }

    func testWhenAPendingReportIsProcessed_itResetsTheUnreadLaunches() throws {
        // Given
        try writeReport(id: 1, contents: #"{"message": "kept"}"#)
        try writeReport(id: 2, contents: #"{"message": "processed"}"#)
        _ = try createPlugin().0.unreadLaunches
        _ = try createPlugin().0.unreadLaunches

        // When
        try createPlugin().0.readPendingCrashReports { $0.message == "processed" ? .processed : .kept }

        // Then
        XCTAssertEqual(try createPlugin().0.unreadLaunches, 0)
    }

    func testWhenNoPendingReportIsProcessed_theLaunchStillCountsAsUnread() throws {
        // Given
        try writeReport(id: 1, contents: #"{"message": "kept"}"#)
        _ = try createPlugin().0.unreadLaunches
        _ = try createPlugin().0.unreadLaunches

        // When (e.g. no feature receives crashes yet)
        try createPlugin().0.readPendingCrashReports { _ in .kept }

        // Then
        XCTAssertEqual(try createPlugin().0.unreadLaunches, 3)
    }

    func testWhenTheLaunchOutlivesTheProcessingDelay_itResetsTheUnreadLaunches() throws {
        // Given
        try writeReport(id: 1, contents: #"{"message": "kept"}"#)
        _ = try createPlugin().0.unreadLaunches
        _ = try createPlugin().0.unreadLaunches

        // When (the reports are kept, e.g. as consent is still pending)
        let (plugin, _) = try createPlugin()
        plugin.resetUnreadLaunches()
        plugin.readPendingCrashReports { _ in .kept }

        // Then
        XCTAssertEqual(try createPlugin().0.unreadLaunches, 0)
    }

    func testGivenReportsKeptAtEveryLaunch_launchesThatOutliveTheDelayNeverCountAsUnread() throws {
        // Given (consent stays pending: every read keeps the report)
        try writeReport(id: 1, contents: #"{"message": "kept"}"#)

        // When
        let counts = try (0..<3).map { _ -> Int in
            let (plugin, _) = try createPlugin()
            let unreadLaunches = plugin.unreadLaunches
            plugin.resetUnreadLaunches()
            plugin.readPendingCrashReports { _ in .kept }
            return unreadLaunches
        }

        // Then
        XCTAssertEqual(counts, [0, 0, 0], "reports must not be read early when no launch ended before the delay")
    }

    func testWhenThereIsNoPendingReport_itCountsNoUnreadLaunch() throws {
        // Given
        _ = try createPlugin().0.unreadLaunches

        // When
        let (plugin, _) = try createPlugin()

        // Then
        XCTAssertEqual(plugin.unreadLaunches, 0)
    }

    func testWhenReportsWereDeleted_theLastLaunchDidNotCrash() throws {
        // Given
        try writeReport(id: 5, contents: #"{"message": "processed"}"#)
        XCTAssertTrue(try createPlugin().0.crashedLastLaunch)
        let (processing, store) = try createPlugin()
        processing.readPendingCrashReports { _ in .processed }
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
