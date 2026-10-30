/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import XCTest
import DatadogInternal
import TestUtilities
@testable import DatadogCrashReporting

class CrashBeaconTests: XCTestCase {
    private var directory: URL! // swiftlint:disable:this implicitly_unwrapped_optional
    private let crashId = "6f9619ff-8b86-d011-b42d-00c04fc964ff"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("crash-beacon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var results: CrashBeaconResults { CrashBeaconResults(directory: directory) }

    private func writeRecord(result: UInt8, duration: Int32, crashId: String) throws {
        var record = Data([result])
        withUnsafeBytes(of: duration.littleEndian) { record.append(contentsOf: $0) }
        record.append(contentsOf: Array(crashId.utf8))
        try record.write(to: results.url(forCrashId: crashId))
    }

    func testItReadsTheResultOfACrashUntilItIsRemoved() throws {
        try writeRecord(result: 1, duration: 412, crashId: crashId)

        XCTAssertEqual(results.result(forCrashId: crashId), CrashBeaconResult(status: .sent, duration: 412))
        XCTAssertNotNil(results.result(forCrashId: crashId), "A report kept for a later launch reads it again")

        results.remove(crashId: crashId)
        XCTAssertNil(results.result(forCrashId: crashId))
    }

    func testItKeepsTheResultsOfTwoCrashesApart() throws {
        let otherId = "00000000-0000-0000-0000-000000000000"
        try writeRecord(result: 1, duration: 100, crashId: crashId)
        try writeRecord(result: 2, duration: 1_000, crashId: otherId)

        XCTAssertEqual(results.result(forCrashId: crashId)?.status, .sent)
        XCTAssertEqual(results.result(forCrashId: otherId)?.status, .timeout)
    }

    func testItMapsEveryRecordedResult() throws {
        let expected: [UInt8: CrashBeaconResult.Status] = [1: .sent, 2: .timeout, 3: .failed, 4: .skipped]
        for (byte, status) in expected {
            try writeRecord(result: byte, duration: 1_000, crashId: crashId)
            XCTAssertEqual(results.result(forCrashId: crashId)?.status, status)
        }
    }

    func testItIgnoresAMalformedRecord() throws {
        try Data([1, 2, 3]).write(to: results.url(forCrashId: crashId))

        XCTAssertNil(results.result(forCrashId: crashId))
    }

    func testItFindsTheCrashIdOfAResultWrittenAroundACrash() throws {
        try writeRecord(result: 1, duration: 100, crashId: crashId)

        XCTAssertEqual(results.crashId(recordedAround: Date()), crashId)
        XCTAssertNil(results.crashId(recordedAround: Date().addingTimeInterval(-3_600)), "A result of another crash")
    }

    func testItRemovesOnlyExpiredResults() throws {
        try writeRecord(result: 1, duration: 100, crashId: crashId)

        results.removeExpired(now: Date())
        XCTAssertNotNil(results.result(forCrashId: crashId))

        results.removeExpired(now: Date().addingTimeInterval(CrashBeaconResults.retention + 60))
        XCTAssertNil(results.result(forCrashId: crashId))
    }

    func testPayloadUsesTheEngineFieldNames() throws {
        let payload = CrashBeacon.Payload(
            crashId: crashId, applicationId: "app", launchTime: 1_000, date: 2_000,
            crashType: "SIGSEGV", crashMessage: nil, sessionId: "s", viewId: "v", viewUrl: "u", viewName: "n",
            usrAnonymousId: "a", usrId: nil, version: "1.0", env: "prod", service: "svc",
            osName: "iOS", osVersion: "18.0", deviceModel: "iPhone16,1", deviceType: "mobile",
            sdkVersion: "0.8.0", source: "ios"
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])

        for key in ["crash_id", "application_id", "launch_time", "date", "crash_type", "session_id", "view_id",
                    "view_url", "view_name", "usr_anonymous_id", "version", "env", "service", "os_name",
                    "os_version", "device_model", "device_type", "sdk_version", "source"] {
            XCTAssertNotNil(json[key], "missing \(key)")
        }
        XCTAssertNil(json["crash_message"], "An absent field is left out, not sent as null")
    }

    func testSignalNames() {
        XCTAssertEqual(CrashBeacon.signalName(SIGSEGV), "SIGSEGV")
        XCTAssertEqual(CrashBeacon.signalName(SIGTRAP), "SIGTRAP")
        XCTAssertEqual(CrashBeacon.signalName(SIGABRT), "SIGABRT")
    }

    // MARK: - With the crash reporting feature

    private func report(crashId: String?, outcome: CrashReportOutcome, context: CrashContext? = nil) -> (CrashReportingFeature, CrashReportingPluginMock, CrashReportSenderMock) {
        var crashContext = context ?? .mockWith(trackingConsent: .granted)
        crashContext.crashId = crashId
        let plugin = CrashReportingPluginMock()
        plugin.pendingCrashReports = [.mockRandomWith(context: crashContext)]
        let sender = CrashReportSenderMock()
        sender.crashReportOutcome = outcome
        let feature = CrashReportingFeature.mockWith(integration: sender, crashReportingPlugin: plugin, beaconDirectory: directory)
        return (feature, plugin, sender)
    }

    func testGivenAKeptReport_itKeepsItsResultForTheNextRead() throws {
        try writeRecord(result: 1, duration: 412, crashId: crashId)
        let (feature, _, sender) = report(crashId: crashId, outcome: .kept)

        feature.start()
        feature.flush()

        XCTAssertEqual(sender.sentCrashContext?.crashBeaconResult?.status, .sent)
        XCTAssertNotNil(results.result(forCrashId: crashId), "The report is read again on a later launch")
    }

    func testGivenAProcessedReport_itRemovesItsResult() throws {
        try writeRecord(result: 1, duration: 412, crashId: crashId)
        let (feature, _, sender) = report(crashId: crashId, outcome: .processed)

        feature.start()
        feature.flush()

        XCTAssertEqual(sender.sentCrashContext?.crashBeaconResult, CrashBeaconResult(status: .sent, duration: 412))
        XCTAssertNil(results.result(forCrashId: crashId))
    }

    func testGivenAReportWithoutContext_itTakesTheCrashIdOfTheResultWrittenAroundTheCrash() throws {
        try writeRecord(result: 1, duration: 412, crashId: crashId)
        let plugin = CrashReportingPluginMock()
        plugin.pendingCrashReports = [.mockWith(date: Date(), context: nil)]
        let sender = CrashReportSenderMock()
        let feature = CrashReportingFeature.mockWith(
            integration: sender,
            crashReportingPlugin: plugin,
            crashContextProvider: CrashContextProviderMock(initialCrashContext: .mockWith(trackingConsent: .granted)),
            beaconDirectory: directory
        )

        feature.start()
        feature.flush()

        XCTAssertEqual(sender.sentCrashContext?.crashId, crashId, "Otherwise the beacon and the report count as two crashes")
    }

    func testGivenAReportWithoutCrashId_itDoesNotTouchTheResults() throws {
        try writeRecord(result: 1, duration: 412, crashId: crashId)
        let (feature, _, sender) = report(crashId: nil, outcome: .processed)

        feature.start()
        feature.flush()

        XCTAssertNil(sender.sentCrashContext?.crashBeaconResult)
        XCTAssertNotNil(results.result(forCrashId: crashId))
    }
}
