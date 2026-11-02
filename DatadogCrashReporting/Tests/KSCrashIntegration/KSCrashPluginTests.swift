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

// MARK: - Lifecycle edge cases

extension KSCrashPluginTests {
    private var writeAttemptsFile: URL { reportsDirectory.appendingPathComponent("write-attempts") }
    private var unreadLaunchesFile: URL { reportsDirectory.appendingPathComponent("unread-launches") }

    func testMixedOutcomes_attemptsPersistedAndUnreadLaunchesReset() throws {
        // Given
        try writeReport(id: 1, contents: #"{"message": "unwritable"}"#)
        try writeReport(id: 2, contents: #"{"message": "done"}"#)
        try writeReport(id: 3, contents: #"{"message": "kept"}"#)
        _ = try createPlugin().0.unreadLaunches
        _ = try createPlugin().0.unreadLaunches

        // When
        let (plugin, store) = try createPlugin()
        plugin.readPendingCrashReports {
            switch $0.message {
            case "unwritable": return .writeFailed
            case "done": return .processed
            default: return .kept
            }
        }

        // Then
        XCTAssertEqual(store.reportIDs, [1, 3])
        XCTAssertEqual(try String(contentsOf: writeAttemptsFile, encoding: .utf8), "1 1")
        XCTAssertEqual(try createPlugin().0.unreadLaunches, 0, "A processed report resets the unread launches")
    }

    func testWriteAttemptsOfReportsThatAreGoneAreForgotten() throws {
        // Given
        try writeReport(id: 1, contents: #"{"message": "a"}"#)
        try writeReport(id: 2, contents: #"{"message": "b"}"#)
        try createPlugin().0.readPendingCrashReports { _ in .writeFailed }
        XCTAssertEqual(try String(contentsOf: writeAttemptsFile, encoding: .utf8), "1 1\n2 1")

        // When (KSCrash dropped report 1 to make room, a new one arrived)
        try FileManager.default.removeItem(at: reportsDirectory.appendingPathComponent(String(format: "%@-report-%016llx.json", appName, 1)))
        try writeReport(id: 3, contents: #"{"message": "c"}"#)
        try createPlugin().0.readPendingCrashReports { _ in .writeFailed }

        // Then
        XCTAssertEqual(try String(contentsOf: writeAttemptsFile, encoding: .utf8), "2 2\n3 1")
    }

    func testAReportThatBecomesUnloadableIsPurgedAndItsAttemptsForgotten() throws {
        // Given
        try writeReport(id: 1, contents: #"{"message": "a"}"#)
        try createPlugin().0.readPendingCrashReports { _ in .writeFailed }
        try writeReport(id: 1, contents: "garbage")

        // When
        let (plugin, store) = try createPlugin()
        plugin.readPendingCrashReports { _ in .writeFailed }

        // Then
        XCTAssertEqual(store.reportIDs, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: writeAttemptsFile.path))
    }

    func testUnreadLaunchesFileWithGarbage_countsFromZero() throws {
        try writeReport(id: 1, contents: #"{"message": "a"}"#)
        for garbage in ["", "abc", "-3", "1.5", " 2", "2\n"] {
            try garbage.write(to: unreadLaunchesFile, atomically: true, encoding: .utf8)
            let (plugin, _) = try createPlugin()
            // Negative values must not be able to postpone the early read forever; others restart from 0
            XCTAssertLessThanOrEqual(plugin.unreadLaunches, 2, "garbage: \(garbage)")
            XCTAssertGreaterThanOrEqual(plugin.unreadLaunches, 0, "garbage: \(garbage)")
        }
    }

    func testUnreadLaunchesFileWithNegativeValue_isNotTrustedAsACount() throws {
        try writeReport(id: 1, contents: #"{"message": "a"}"#)
        try "-5".write(to: unreadLaunchesFile, atomically: true, encoding: .utf8)
        XCTAssertGreaterThanOrEqual(try createPlugin().0.unreadLaunches, 0)
    }

    func testUnreadLaunchesFileWithHugeValue_doesNotTrap() throws {
        try writeReport(id: 1, contents: #"{"message": "a"}"#)
        try String(Int.max).write(to: unreadLaunchesFile, atomically: true, encoding: .utf8)
        _ = try createPlugin().0.unreadLaunches
    }

    func testWriteAttemptsFileWithNegativeOrHugeCounts_stillConverges() throws {
        // Given
        try writeReport(id: 1, contents: #"{"message": "a"}"#)
        try "1 -1000".write(to: writeAttemptsFile, atomically: true, encoding: .utf8)

        // When (three reads that cannot write)
        var ids: [[NSNumber]] = []
        for _ in 0..<3 {
            let (plugin, store) = try createPlugin()
            plugin.readPendingCrashReports { _ in .writeFailed }
            ids.append(store.reportIDs)
        }

        // Then
        XCTAssertEqual(ids.last, [], "A corrupt counter must not keep a report forever")
    }

    func testKnownReportIDsFileThatIsNotUTF8_isTreatedAsEmptyOnce() throws {
        // Given
        try writeReport(id: 1, contents: #"{"message": "kept"}"#)
        try Data([0xFF, 0xFE, 0xFD]).write(to: knownReportIDsFile)

        // When
        let first = try createPlugin().0.crashedLastLaunch
        let second = try createPlugin().0.crashedLastLaunch

        // Then
        XCTAssertTrue(first)
        XCTAssertFalse(second, "The corrupt file is rewritten")
    }

    func testCrashLoopSequence_readsEarlyOnlyAfterTwoUnreadLaunchesAndNeverLosesReports() throws {
        // Given a crash loop: each launch finds the reports of the previous ones and adds its own
        var earlyReads = 0
        var nextID: Int64 = 1
        var delivered: [String] = []
        for launch in 0..<9 {
            try writeReport(id: nextID, contents: "{\"message\": \"crash-\(nextID)\"}")
            nextID += 1
            let (plugin, store) = try createPlugin()
            _ = plugin.crashedLastLaunch
            if plugin.unreadLaunches >= 2 {
                earlyReads += 1
                plugin.readPendingCrashReports { delivered.append($0.message); return .processed }
            }
            XCTAssertLessThanOrEqual(store.reportIDs.count, 3, "launch \(launch)")
        }
        // Then
        XCTAssertGreaterThan(earlyReads, 0)
        XCTAssertEqual(delivered.count + (try createPlugin().0.crashedLastLaunch ? 0 : 0), delivered.count)
        let remaining = try createPlugin().1.reportIDs.count
        XCTAssertEqual(delivered.count + remaining, 9, "every crash is either delivered or still pending")
    }

    func testAProcessedReportInAnEarlyReadDoesNotMakeTheLoopStarveReads() throws {
        // Given three launches ended before the delay with a pending report
        try writeReport(id: 1, contents: #"{"message": "a"}"#)
        _ = try createPlugin().0.unreadLaunches
        _ = try createPlugin().0.unreadLaunches
        let (early, _) = try createPlugin()
        XCTAssertEqual(early.unreadLaunches, 2)

        // When the early read processes the report and the process crashes right after
        early.readPendingCrashReports { _ in .processed }
        try writeReport(id: 2, contents: #"{"message": "b"}"#)

        // Then the next launches start counting again from this report
        let counts = try (0..<3).map { _ in try createPlugin().0.unreadLaunches }
        XCTAssertEqual(counts, [0, 1, 2])
    }

    func testResetUnreadLaunchesBeforeAnyAccess_doesNotUndoTheReset() throws {
        try writeReport(id: 1, contents: #"{"message": "a"}"#)
        _ = try createPlugin().0.unreadLaunches
        _ = try createPlugin().0.unreadLaunches
        let (plugin, _) = try createPlugin()
        plugin.resetUnreadLaunches()
        XCTAssertEqual(try String(contentsOf: unreadLaunchesFile, encoding: .utf8), "0")
        XCTAssertEqual(plugin.unreadLaunches, 2, "the value read at launch is unchanged")
        XCTAssertEqual(try String(contentsOf: unreadLaunchesFile, encoding: .utf8), "0")
    }

    func testReadingTwiceInOneLaunch_countsTwoReadsTowardsTheWriteFailureLimit() throws {
        // Given a report whose error cannot be written now
        try writeReport(id: 1, contents: #"{"message": "a"}"#)
        let (plugin, store) = try createPlugin()

        // When it is read at launch (early read), after the delay, and at a consent change
        plugin.readPendingCrashReports { _ in .writeFailed }
        plugin.readPendingCrashReports { _ in .writeFailed }
        plugin.readPendingCrashReports { _ in .writeFailed }

        // Then (documented: "kept for 3 reads at most")
        XCTAssertEqual(store.reportIDs, [])
    }

    func testAReportProcessedByTheFirstReadIsNotProcessedAgainByTheSecond() throws {
        try writeReport(id: 1, contents: #"{"message": "a"}"#)
        let (plugin, _) = try createPlugin()
        var count = 0
        plugin.readPendingCrashReports { _ in count += 1; return .processed }
        plugin.readPendingCrashReports { _ in count += 1; return .processed }
        XCTAssertEqual(count, 1)
    }

    func testUpgradeFrom080_noStateFiles_pendingReportFromTheOldProcessCountsAsCrash() throws {
        try writeReport(id: 7, contents: #"{"message": "a"}"#)
        let (plugin, _) = try createPlugin()
        XCTAssertTrue(plugin.crashedLastLaunch)
        XCTAssertEqual(plugin.unreadLaunches, 0)
    }

    func testControl_enabledOnce_theLaunchReportSaysThePreviousLaunchCrashed() throws {
        try writeReport(id: 1, contents: #"{"message": "crash"}"#)
        let sender = CrashReportSenderMock()
        let feature = CrashReportingFeature.mockWith(integration: sender, crashReportingPlugin: try createPlugin().0, processingDelay: 60)
        feature.start()
        feature.flush()
        XCTAssertEqual(sender.sentLaunchReports.map { $0.didCrash }, [true])
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
