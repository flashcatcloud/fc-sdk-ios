/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import XCTest
import DatadogInternal
import TestUtilities
@testable import DatadogCrashReporting
// swiftlint:disable duplicate_imports
#if SPM_BUILD
    #if swift(>=6.0)
    internal import DatadogCrashReportingPrivate
    #else
    @_implementationOnly import DatadogCrashReportingPrivate
    #endif
#endif
// swiftlint:enable duplicate_imports

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

    private func writeRecord(result: UInt8, duration: Int32, crashId: String, launchTime: Int64 = 1_762_300_000_123) throws {
        var record = Data([result])
        withUnsafeBytes(of: duration.littleEndian) { record.append(contentsOf: $0) }
        record.append(contentsOf: Array(crashId.utf8))
        withUnsafeBytes(of: launchTime.littleEndian) { record.append(contentsOf: $0) }
        try record.write(to: results.url(forCrashId: crashId))
    }

    func testItReadsTheResultOfACrashUntilItIsRemoved() throws {
        try writeRecord(result: 1, duration: 412, crashId: crashId)

        XCTAssertEqual(results.result(forCrashId: crashId), CrashBeaconResult(status: .sent, duration: 412, launchTime: 1_762_300_000_123))
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

    func testItReadsTheLaunchTimeOfTheBeacon() throws {
        try writeRecord(result: 2, duration: 1_000, crashId: crashId, launchTime: 1_762_300_000_123)

        XCTAssertEqual(results.result(forCrashId: crashId)?.launchTime, 1_762_300_000_123)
    }

    func testItLeavesOutAnUnsetLaunchTime() throws {
        try writeRecord(result: 4, duration: 0, crashId: crashId, launchTime: 0)

        XCTAssertNil(results.result(forCrashId: crashId)?.launchTime, "Skipped before any context: no launch time to match")
    }

    /// Drives the signal handler's entry point through a whole crash: a first fatal signal, and later ones on other threads.
    ///
    /// The handler keeps the first crash for the life of the process, and can be installed once: this is the only test
    /// that installs it or calls `dd_crash_beacon_handle_crash`, so it does not depend on the order of the others. It
    /// stands for the beacon thread, and records to a FIFO: the first crash then blocks while it records its result,
    /// until this test reads it, which is how it holds a first crash that is not done yet.
    func testALaterCrashWaitsForTheFirstOneUpToTheLimit() throws {
        let signals = [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGPIPE, SIGSEGV, SIGSYS, SIGTRAP]
        let previousActions: [sigaction] = signals.map { signal in
            var action = sigaction()
            sigaction(signal, nil, &action)
            return action
        }
        let previousExceptionHandler = NSGetUncaughtExceptionHandler()
        let fifo = directory.appendingPathComponent("result").path
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        var reader: Int32 = -1
        defer {
            // Lets the first crash go if an assertion failed before its result was read.
            if reader < 0 {
                reader = open(fifo, O_RDONLY | O_NONBLOCK)
            }
            close(reader)
            dd_crash_beacon_set_armed(false)
            for (signal, action) in zip(signals, previousActions) {
                var action = action
                sigaction(signal, &action, nil)
            }
            NSSetUncaughtExceptionHandler(previousExceptionHandler)
        }
        guard dd_crash_beacon_install(fifo, crashId) else {
            throw XCTSkip("The beacon is installed once per process, and not under a debugger")
        }
        dd_crash_beacon_set_timeout_ms(1_000)
        dd_crash_beacon_set_foreground(true)
        dd_crash_beacon_set_armed(true)
        dd_crash_beacon_set_launch_time_ms(1_762_300_000_123)

        func crash(_ signal: Int32) -> (returned: DispatchSemaphore, duration: () -> TimeInterval) {
            let returned = DispatchSemaphore(value: 0)
            let start = Date()
            var end = start
            Thread.detachNewThread {
                dd_crash_beacon_handle_crash(signal)
                end = Date()
                returned.signal()
            }
            return (returned, { end.timeIntervalSince(start) })
        }

        // The first crash wakes the beacon thread, which never answers: it stops waiting at the timeout (1 s), then
        // blocks recording that.
        let first = crash(SIGTRAP)
        XCTAssertEqual(dd_crash_beacon_wait_for_wake(), SIGTRAP)
        dd_crash_beacon_set_launch_time_ms(1_762_300_009_999)

        // A later crash while the first one is not done: held, but not past the limit (1.1 s).
        let heldToTheLimit = crash(SIGSEGV)
        XCTAssertEqual(heldToTheLimit.returned.wait(timeout: .now() + 3), .success, "A first crash that never ends must not hold a later one for good")
        XCTAssertGreaterThanOrEqual(heldToTheLimit.duration(), 1.0, "It must not go on while the first crash waits for its beacon")
        XCTAssertEqual(first.returned.wait(timeout: .now()), .timedOut, "The first crash is still recording its result")

        // Another one, let go as soon as the first crash is done: well before its own limit.
        let heldUntilDone = crash(SIGBUS)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(heldUntilDone.returned.wait(timeout: .now()), .timedOut, "It must not go on while the first crash records its result")
        reader = open(fifo, O_RDONLY | O_NONBLOCK)
        XCTAssertEqual(first.returned.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(heldUntilDone.returned.wait(timeout: .now() + 3), .success)
        XCTAssertLessThan(heldUntilDone.duration(), 0.9, "It must go on once the first crash is done, not at the limit")

        // The first crash is done: a later one goes on at once.
        let start = Date()
        dd_crash_beacon_handle_crash(SIGSEGV)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)

        // What the first crash recorded: the timeout, with the launch time of the moment of the crash.
        var record = [UInt8](repeating: 0, count: Int(DDCrashBeaconRecordSize))
        XCTAssertEqual(read(reader, &record, record.count), record.count)
        try Data(record).write(to: results.url(forCrashId: crashId))
        XCTAssertEqual(results.result(forCrashId: crashId), CrashBeaconResult(status: .timeout, duration: 1_000, launchTime: 1_762_300_000_123))
        XCTAssertEqual(dd_crash_beacon_launch_time_ms(), 1_762_300_000_123, "A context update while the crash waits must not change it")
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
            crashType: "SIGSEGV", crashMessage: nil, sessionId: "s", sessionSampledForError: nil, viewId: "v", viewUrl: "u", viewName: "n",
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
        XCTAssertNil(json["session_sampled_for_error"], "An absent field is left out, not sent as null")
    }

    // MARK: - Session kept on error

    private final class RequestSenderMock: CrashBeaconRequestSender {
        func sendFromCrashingProcess(request: URLRequest, completion: @escaping (Result<HTTPURLResponse, Error>) -> Void) {}
    }

    private func payloadJSON(sessionState: RUMSessionState?, view: RUMViewEvent? = nil) throws -> [String: Any] {
        let beacon = CrashBeacon(crashId: crashId, sender: RequestSenderMock())
        let context: DatadogContext = .mockWith(
            additionalContext: [RUMFatalErrorContext(sessionState: sessionState, view: view, globalAttributes: nil)]
        )
        let source = CrashBeaconSource(url: URL(string: "https://intake.example/crash")!, applicationID: "app")
        let payload = beacon.payload(signal: SIGSEGV, context: context, source: source)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
    }

    func testGivenASessionKeptOnError_itMarksTheBeaconSampledForError() throws {
        let json = try payloadJSON(sessionState: .mockWith(sessionUUID: .mockRandom(), sampledForError: true))

        XCTAssertEqual(json["session_sampled_for_error"] as? Bool, true, "The intake keeps this crash out of the crash-free rate")
    }

    func testGivenASampledSession_itLeavesOutSampledForError() throws {
        for sampledForError in [false, nil] as [Bool?] {
            let json = try payloadJSON(sessionState: .mockWith(sessionUUID: .mockRandom(), sampledForError: sampledForError))

            XCTAssertNil(json["session_sampled_for_error"])
        }
    }

    /// An active view of `sessionID`, marked kept on error or not.
    private func view(sessionID: UUID, sampledForError: Bool) throws -> RUMViewEvent {
        let view = RUMViewEvent.mockRandomWith(sessionID: sessionID, viewIsActive: true)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(view)) as? [String: Any])
        var session = try XCTUnwrap(json["session"] as? [String: Any])
        session["sampled_for_error"] = sampledForError ? true : nil
        json["session"] = session
        return try JSONDecoder().decode(RUMViewEvent.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testGivenAViewOfTheCrashedSessionKeptOnError_itNamesThatViewAndMarksTheBeacon() throws {
        let sessionID: UUID = .mockRandom()
        let view = try view(sessionID: sessionID, sampledForError: true)
        let json = try payloadJSON(sessionState: .mockWith(sessionUUID: sessionID, sampledForError: true), view: view)

        XCTAssertEqual(json["view_id"] as? String, view.view.id)
        XCTAssertEqual(json["session_sampled_for_error"] as? Bool, true)
    }

    func testGivenAStaleViewOfAnOlderSessionKeptOnError_itNamesTheCurrentSessionWithItsOwnFlag() throws {
        let current: UUID = .mockRandom()
        let json = try payloadJSON(
            sessionState: .mockWith(sessionUUID: current, sampledForError: nil),
            view: try view(sessionID: .mockRandom(), sampledForError: true)
        )

        XCTAssertEqual(json["session_id"] as? String, current.uuidString.lowercased())
        XCTAssertNil(json["view_id"], "The view of another session is not the last screen of this one")
        XCTAssertNil(json["session_sampled_for_error"], "The flag of the older session must not be paired with this one")
    }

    func testGivenAStaleViewOfAnOlderSampledSession_itMarksTheCurrentSessionKeptOnError() throws {
        let current: UUID = .mockRandom()
        let json = try payloadJSON(
            sessionState: .mockWith(sessionUUID: current, sampledForError: true),
            view: try view(sessionID: .mockRandom(), sampledForError: false)
        )

        XCTAssertEqual(json["session_id"] as? String, current.uuidString.lowercased())
        XCTAssertEqual(json["session_sampled_for_error"] as? Bool, true)
    }

    func testGivenNoSession_itLeavesOutSampledForError() throws {
        let json = try payloadJSON(sessionState: nil)

        XCTAssertNil(json["session_sampled_for_error"])
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

        XCTAssertEqual(sender.sentCrashContext?.crashBeaconResult, CrashBeaconResult(status: .sent, duration: 412, launchTime: 1_762_300_000_123))
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
        XCTAssertEqual(
            sender.sentCrashContext?.crashBeaconResult?.launchTime, 1_762_300_000_123,
            "Without its own launch date, the report takes the beacon's, or it lands on the crash day"
        )
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
