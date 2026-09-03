/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import DatadogInternal
import TestUtilities
import XCTest
@testable import DatadogCore

class RemoteSamplingControllerTests: XCTestCase {
    private let source = RemoteSamplingSource(
        configurationURL: URL(string: "https://intake.example.com/api/v2/rum/config?client_token=t&sdk=ios")!
    )

    /// A stub client answering each fetch through a programmable handler.
    private final class FetchStub: HTTPClient {
        private let lock = NSLock()
        private var _calls: [URLRequest] = []
        var calls: [URLRequest] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }
        var handler: (URLRequest) -> Result<(response: HTTPURLResponse, body: Data), Error> = { _ in
            .failure(NSError.mockAny())
        }

        func send(request: URLRequest, delegate: URLSessionTaskDelegate?, completion: @escaping (Result<HTTPURLResponse, Error>) -> Void) {}

        func fetch(request: URLRequest, completion: @escaping (Result<(response: HTTPURLResponse, body: Data), Error>) -> Void) {
            // Recorded on receipt, and answered off the caller's thread — the same shape as a real
            // HTTP client. Answering synchronously would run the whole exchange inside the
            // controller's own queue hop, which is precisely when its in-flight guard cannot be
            // observed to do anything.
            lock.lock()
            _calls.append(request)
            lock.unlock()
            let handler = self.handler
            DispatchQueue.global(qos: .utility).async {
                completion(handler(request))
            }
        }
    }

    /// Thread-safe record of everything the controller did.
    private final class Recorder {
        private let lock = NSLock()
        private var _published: [RemoteSamplingRates] = []
        private var _ratesChanged: [RemoteSamplingActivation] = []
        private var _scheduledDelays: [TimeInterval] = []
        private var _pendingWork: [() -> Void] = []

        var published: [RemoteSamplingRates] {
            lock.lock(); defer { lock.unlock() }
            return _published
        }
        var ratesChanged: [RemoteSamplingActivation] {
            lock.lock(); defer { lock.unlock() }
            return _ratesChanged
        }
        var scheduledDelays: [TimeInterval] {
            lock.lock(); defer { lock.unlock() }
            return _scheduledDelays
        }
        var pendingWork: [() -> Void] {
            lock.lock(); defer { lock.unlock() }
            return _pendingWork
        }

        func publish(_ rates: RemoteSamplingRates) {
            lock.lock(); _published.append(rates); lock.unlock()
        }
        func notifyRatesChanged(_ activation: RemoteSamplingActivation) {
            lock.lock(); _ratesChanged.append(activation); lock.unlock()
        }
        func schedule(_ delay: TimeInterval, work: @escaping () -> Void) {
            lock.lock()
            _scheduledDelays.append(delay)
            _pendingWork.append(work)
            lock.unlock()
        }
    }

    private struct Harness {
        let client = FetchStub()
        let recorder = Recorder()
        let controller: RemoteSamplingController

        init(store: RemoteSamplingSnapshotStore? = nil, context: DatadogContext = .mockAny()) {
            let recorder = self.recorder
            controller = RemoteSamplingController(
                httpClient: client,
                contextProvider: DatadogContextProvider(context: context),
                store: store,
                telemetry: NOPTelemetry(),
                publishRates: { recorder.publish($0) },
                notifyRatesChanged: { recorder.notifyRatesChanged($0) },
                schedule: { recorder.schedule($0, work: $1) },
                jitter: { $0 } // no jitter in tests
            )
        }
    }

    /// Waits until `condition` holds, polling briefly; every controller hop is async.
    private func eventually(
        _ condition: @autoclosure () -> Bool,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "condition not met within \(timeout)s", file: file, line: line)
    }

    // MARK: - Fetch model

    func testTriggerFetchesConfiguration() {
        let harness = Harness()
        harness.client.handler = { _ in
            .success((.mockResponseWith(statusCode: 200), #"{ "schema_version": 1, "version": 1, "enabled": true, "rum": { "sessionSampleRate": 20 } }"#.data(using: .utf8)!))
        }

        harness.controller.onSourcePublished(source)

        eventually(harness.client.calls.count == 1)
        eventually(harness.recorder.published.count == 1)
        XCTAssertEqual(harness.recorder.published.last?.sessionSampleRate, 20)
        XCTAssertEqual(harness.recorder.published.last?.version, 1)
    }

    func testInFlightFetchDeduplicatesTriggers() {
        let harness = Harness()
        let gate = DispatchSemaphore(value: 0)
        harness.client.handler = { _ in
            gate.wait()
            return .success((.mockResponseWith(statusCode: 200), #"{ "schema_version": 1, "version": 1, "enabled": true, "rum": {} }"#.data(using: .utf8)!))
        }

        harness.controller.onSourcePublished(source)
        eventually(harness.client.calls.count == 1)
        harness.controller.onSourcePublished(source)
        harness.controller.onSourcePublished(source)
        // A trigger reaches the guard only after an asynchronous context read, so it must be given
        // that hop before the fetch is released — otherwise this would be measuring which of the
        // two landed first rather than whether the guard held.
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        gate.signal()

        eventually(harness.recorder.published.count == 1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(harness.client.calls.count, 1, "triggers during a fetch must not start another one")
    }

    func testAppliedVersionIsSentOnceKnown() {
        let harness = Harness()
        harness.client.handler = { _ in
            .success((.mockResponseWith(statusCode: 200), #"{ "schema_version": 1, "version": 42, "enabled": true, "rum": {} }"#.data(using: .utf8)!))
        }

        harness.controller.onSourcePublished(source)
        // Wait for the exchange to finish, not merely for the request to go out. The version this
        // test is about is only known once the answer has been applied, and the same act of
        // applying it is what releases the in-flight guard — so triggering again on the strength of
        // the request alone races the response and the second trigger is sometimes dropped.
        eventually(harness.recorder.published.count == 1)
        XCTAssertEqual(harness.client.calls.count, 1)
        let firstQuery = URLComponents(url: harness.client.calls[0].url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertNil(firstQuery?.first(where: { $0.name == "applied_version" }), "no version to report on the very first request")

        harness.controller.onSourcePublished(source)
        eventually(harness.client.calls.count == 2)
        let query = URLComponents(url: harness.client.calls[1].url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "applied_version" })?.value, "42")
    }

    // MARK: - ETag & 304

    func testTheServersETagIsSentBackAsIfNoneMatch() {
        let harness = Harness()
        let body = #"{ "schema_version": 1, "version": 1, "enabled": true, "rum": {} }"#.data(using: .utf8)!
        // Deliberately not any hash of the body: the client must send back what the server
        // stamped, not something it derived itself. A client that recomputes the validator has to
        // track the server's derivation forever, and the day the two drift apart every conditional
        // request misses in silence — full answers, no error, nothing to notice.
        let serverETag = "\"not-a-hash-of-the-body\""
        harness.client.handler = { _ in
            .success((.mockResponseWith(statusCode: 200, headerFields: ["ETag": serverETag]), body))
        }

        harness.controller.onSourcePublished(source)
        eventually(harness.recorder.published.count == 1)

        harness.client.handler = { _ in .success((.mockResponseWith(statusCode: 304), Data())) }
        harness.controller.onSourcePublished(source)

        eventually(harness.client.calls.count == 2)
        XCTAssertEqual(harness.client.calls[1].value(forHTTPHeaderField: "If-None-Match"), serverETag)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(harness.recorder.published.count, 1, "a 304 changes nothing")
    }

    func testTheETagHeaderIsFoundWhateverCaseTheServerWroteIt() {
        let harness = Harness()
        let body = #"{ "schema_version": 1, "version": 1, "enabled": true, "rum": {} }"#.data(using: .utf8)!
        harness.client.handler = { _ in
            // HTTP field names are case-insensitive and servers differ; `Etag` is as valid as `ETag`.
            .success((.mockResponseWith(statusCode: 200, headerFields: ["Etag": "\"abc\""]), body))
        }

        harness.controller.onSourcePublished(source)
        eventually(harness.recorder.published.count == 1)

        harness.controller.onSourcePublished(source)
        eventually(harness.client.calls.count == 2)
        XCTAssertEqual(harness.client.calls[1].value(forHTTPHeaderField: "If-None-Match"), "\"abc\"")
    }

    func testAResponseWithNoETagLeavesTheNextRequestUnconditional() {
        let harness = Harness()
        let body = #"{ "schema_version": 1, "version": 1, "enabled": true, "rum": {} }"#.data(using: .utf8)!
        harness.client.handler = { _ in .success((.mockResponseWith(statusCode: 200), body)) }

        harness.controller.onSourcePublished(source)
        eventually(harness.recorder.published.count == 1)

        harness.controller.onSourcePublished(source)
        eventually(harness.client.calls.count == 2)
        XCTAssertNil(
            harness.client.calls[1].value(forHTTPHeaderField: "If-None-Match"),
            "with nothing to revalidate against, asking in full is the only honest request"
        )
    }

    // MARK: - Backoff

    func testFailureRetriesAt5sThen60sThenWaitsForNextTrigger() {
        let harness = Harness()
        harness.client.handler = { _ in .failure(NSError.mockAny()) }

        harness.controller.onSourcePublished(source)
        eventually(harness.client.calls.count == 1)
        eventually(harness.recorder.scheduledDelays.count == 1)
        XCTAssertEqual(harness.recorder.scheduledDelays[0], 5)

        harness.recorder.pendingWork[0]()
        eventually(harness.client.calls.count == 2)
        eventually(harness.recorder.scheduledDelays.count == 2)
        XCTAssertEqual(harness.recorder.scheduledDelays[1], 60)

        harness.recorder.pendingWork[1]()
        eventually(harness.client.calls.count == 3)
        // Asserting that nothing more was scheduled means waiting long enough to be sure nothing
        // will be — there is no arrival to wait on. The window is generous: retries are scheduled
        // inside the same hop that handles the response, so anything coming at all comes at once.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(harness.recorder.scheduledDelays.count, 2, "after two retries the controller waits for the next trigger")

        // A new trigger is a fresh opportunity, with its own two retries:
        harness.controller.onSourcePublished(source)
        eventually(harness.client.calls.count == 4)
    }

    func testSuccessResetsBackoff() {
        let harness = Harness()
        harness.client.handler = { _ in .failure(NSError.mockAny()) }

        harness.controller.onSourcePublished(source)
        eventually(harness.recorder.scheduledDelays.count == 1)

        harness.client.handler = { _ in
            .success((.mockResponseWith(statusCode: 200), #"{ "schema_version": 1, "version": 1, "enabled": true, "rum": {} }"#.data(using: .utf8)!))
        }
        harness.recorder.pendingWork[0]()
        eventually(harness.recorder.published.count == 1)
        XCTAssertEqual(harness.recorder.scheduledDelays.count, 1, "a successful retry schedules nothing further")
    }

    func testUnsupportedSchemaKeepsOldValuesAndDoesNotRetry() {
        let harness = Harness()
        harness.client.handler = { _ in
            .success((.mockResponseWith(statusCode: 200), #"{ "schema_version": 1, "version": 1, "enabled": true, "rum": { "sessionSampleRate": 20 } }"#.data(using: .utf8)!))
        }

        harness.controller.onSourcePublished(source)
        eventually(harness.recorder.published.count == 1)

        harness.client.handler = { _ in
            .success((.mockResponseWith(statusCode: 200), #"{ "schema_version": 99, "version": 2, "enabled": true, "rum": { "sessionSampleRate": 90 } }"#.data(using: .utf8)!))
        }
        harness.controller.onSourcePublished(source)
        eventually(harness.client.calls.count == 2)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        // The server answered; this SDK cannot use the answer. Retrying would fetch the same
        // refusal, so nothing is scheduled — and nothing of the refused body is published.
        XCTAssertEqual(harness.recorder.scheduledDelays.count, 0)
        XCTAssertEqual(harness.recorder.published.count, 1)
        XCTAssertEqual(harness.recorder.published.last?.sessionSampleRate, 20)
    }

    func testUnsupportedSchemaDoesNotWedgeTheController() {
        let harness = Harness()
        harness.client.handler = { _ in
            .success((.mockResponseWith(statusCode: 200), #"{ "schema_version": 99, "version": 1, "enabled": true, "rum": {} }"#.data(using: .utf8)!))
        }

        harness.controller.onSourcePublished(source)
        eventually(harness.client.calls.count == 1)

        // A refused body publishes nothing, so there is no state to wait on: give the controller
        // the hop it needs to finish refusing, or the next trigger races the in-flight guard being
        // released and is sometimes dropped.
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        // A refusal must still end the fetch: the next trigger has to reach the network.
        harness.controller.onSourcePublished(source)
        eventually(harness.client.calls.count == 2)
    }

    func testInvalidSnapshotKeepsOldValuesAndRetries() {
        let harness = Harness()
        harness.client.handler = { _ in
            .success((.mockResponseWith(statusCode: 200), #"{ "schema_version": 1, "version": 1, "enabled": true, "rum": { "sessionSampleRate": 20 } }"#.data(using: .utf8)!))
        }

        harness.controller.onSourcePublished(source)
        eventually(harness.recorder.published.count == 1)

        // An unreadable answer must not wipe the values in effect:
        harness.client.handler = { _ in .success((.mockResponseWith(statusCode: 200), "garbage".data(using: .utf8)!)) }
        harness.controller.onSourcePublished(source)
        eventually(harness.recorder.scheduledDelays.count == 1)
        XCTAssertEqual(harness.recorder.published.count, 1, "an invalid snapshot is rejected whole, the old one stays")
    }

    // MARK: - Kill switch

    func testKillSwitchClearsValuesKeepsVersion() {
        let harness = Harness()
        harness.client.handler = { _ in
            .success((.mockResponseWith(statusCode: 200), #"""
            { "schema_version": 1, "version": 42, "enabled": true, "rum": { "sessionSampleRate": 20 }, "custom": { "a": 1 } }
            """#.data(using: .utf8)!))
        }

        harness.controller.onSourcePublished(source)
        eventually(harness.recorder.published.count == 1)
        XCTAssertEqual(harness.recorder.published.last?.sessionSampleRate, 20)
        XCTAssertEqual(harness.recorder.published.last?.custom, #"{"a":1}"#)

        harness.client.handler = { _ in
            .success((.mockResponseWith(statusCode: 200), #"{ "schema_version": 1, "version": 43, "enabled": false, "rum": {} }"#.data(using: .utf8)!))
        }
        harness.controller.onSourcePublished(source)

        eventually(harness.recorder.published.count == 2)
        let rates = harness.recorder.published.last
        XCTAssertNil(rates?.sessionSampleRate)
        XCTAssertNil(rates?.custom)
        XCTAssertEqual(rates?.version, 43, "the version survives the kill switch")
    }

    // MARK: - Immediate activation

    func testEveryRealRateChangeIsReportedWithTheConsolesInstruction() {
        // The core reports the change and carries what the console asked for; it does not rule on
        // it. A rate of zero ends the running session on its own meaning, and only RUM can see
        // that, so filtering to `immediate` here would hide it.
        let harness = Harness()
        harness.client.handler = { _ in
            .success((.mockResponseWith(statusCode: 200), #"{ "schema_version": 1, "version": 1, "enabled": true, "activation": "immediate", "rum": { "sessionSampleRate": 20 } }"#.data(using: .utf8)!))
        }

        harness.controller.onSourcePublished(source)
        eventually(harness.recorder.published.count == 1)
        XCTAssertEqual(harness.recorder.ratesChanged, [.immediate], "the draw changed from nothing to 20")

        // Same rates again: nothing changed, so there is nothing to report.
        harness.controller.onSourcePublished(source)
        eventually(harness.recorder.published.count == 2)
        XCTAssertEqual(harness.recorder.ratesChanged, [.immediate])

        // A real change the console did not mark `immediate` is still a real change.
        harness.client.handler = { _ in
            .success((.mockResponseWith(statusCode: 200), #"{ "schema_version": 1, "version": 2, "enabled": true, "rum": { "sessionSampleRate": 0 } }"#.data(using: .utf8)!))
        }
        harness.controller.onSourcePublished(source)
        eventually(harness.recorder.published.count == 3)
        XCTAssertEqual(harness.recorder.ratesChanged, [.immediate, .nextSession])
    }

    // MARK: - Stale configuration

    func testAConfigurationOlderThanTheOneInForceIsRefusedWithoutWedgingTheController() {
        // Versions only climb: a rollback in the console republishes the older content under a new
        // number. So a body carrying a lower one is a stale copy — an edge cache or a proxy
        // answering 200 with something it held on to. Applying it would put this client back on
        // settings the console has already replaced, and it would go on reporting that older
        // number, so the rollout view would read as the change losing ground.
        let harness = Harness()
        harness.client.handler = { _ in
            .success((.mockResponseWith(statusCode: 200), #"{ "schema_version": 1, "version": 42, "enabled": true, "rum": { "sessionSampleRate": 20 } }"#.data(using: .utf8)!))
        }

        harness.controller.onSourcePublished(source)
        eventually(harness.recorder.published.count == 1)
        XCTAssertEqual(harness.recorder.published.last?.version, 42)

        // A stale answer arrives, and it carries a rate that would be very visible if applied.
        harness.client.handler = { _ in
            .success((.mockResponseWith(statusCode: 200), #"{ "schema_version": 1, "version": 41, "enabled": true, "rum": { "sessionSampleRate": 90 } }"#.data(using: .utf8)!))
        }
        harness.controller.onSourcePublished(source)
        eventually(harness.client.calls.count == 2)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(harness.recorder.published.count, 1, "the stale body is refused whole")
        XCTAssertEqual(harness.recorder.published.last?.sessionSampleRate, 20, "the values in force are untouched")

        // And refusing one must not leave the controller deaf: the next real change still lands.
        harness.client.handler = { _ in
            .success((.mockResponseWith(statusCode: 200), #"{ "schema_version": 1, "version": 43, "enabled": true, "rum": { "sessionSampleRate": 90 } }"#.data(using: .utf8)!))
        }
        harness.controller.onSourcePublished(source)

        eventually(harness.recorder.published.count == 2)
        XCTAssertEqual(harness.recorder.published.last?.version, 43)
        XCTAssertEqual(harness.recorder.published.last?.sessionSampleRate, 90)
    }

    func testAConfigurationForAnotherIdentityIsNotJudgedAgainstThisOnesVersion() {
        // Versions are counted per application, so an entry belonging to another one is not merely
        // wrong — it is ahead. Without dropping it when the identity changes, the guard above would
        // refuse every answer the new identity gives until its own count passed the old one, and
        // the wrong rates would hold for as long as that took. Nothing about that self-heals.
        let harness = Harness()
        harness.client.handler = { _ in
            .success((.mockResponseWith(statusCode: 200), #"{ "schema_version": 1, "version": 42, "enabled": true, "rum": { "sessionSampleRate": 20 } }"#.data(using: .utf8)!))
        }
        harness.controller.onSourcePublished(source)
        eventually(harness.recorder.published.count == 1)
        XCTAssertEqual(harness.recorder.published.last?.version, 42)

        // A different identity — here a different intake, which lands in the key the same way a
        // different client token does — answering with its own, much lower, version.
        let otherIdentity = RemoteSamplingSource(
            configurationURL: URL(string: "https://other.example.com/api/v2/rum/config?client_token=t&sdk=ios")!
        )
        harness.client.handler = { _ in
            .success((.mockResponseWith(statusCode: 200), #"{ "schema_version": 1, "version": 1, "enabled": true, "rum": { "sessionSampleRate": 90 } }"#.data(using: .utf8)!))
        }
        harness.controller.onSourcePublished(otherIdentity)

        eventually(harness.recorder.published.count == 2)
        XCTAssertEqual(harness.recorder.published.last?.version, 1, "the new identity starts from its own count")
        XCTAssertEqual(harness.recorder.published.last?.sessionSampleRate, 90)
    }

    // MARK: - Persistence

    func testStoredSnapshotAppliesBeforeNetworkAnswers() throws {
        CreateTemporaryDirectory()
        defer { DeleteTemporaryDirectory() }

        let store = try makeStore()
        store.save(
            RemoteSamplingSnapshot(
                version: 42,
                etag: "\"0123456789abcdef\"",
                enabled: true,
                sessionSampleRate: 20,
                custom: nil
            ),
            forKey: RemoteSamplingSnapshotStore.key(source: source, context: .mockAny())
        )
        let harness = Harness(store: store, context: .mockAny())
        harness.client.handler = { _ in .failure(NSError.mockAny()) }

        harness.controller.onSourcePublished(source)

        eventually(harness.recorder.published.count == 1)
        XCTAssertEqual(harness.recorder.published.last?.sessionSampleRate, 20, "the persisted values apply before the fetch answers")
        eventually(harness.client.calls.count == 1)
        let request = harness.client.calls[0]
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "\"0123456789abcdef\"")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "applied_version" })?.value, "42")
    }

    func testSnapshotIsPersistedOnSuccess() throws {
        CreateTemporaryDirectory()
        defer { DeleteTemporaryDirectory() }

        let store = try makeStore()
        let harness = Harness(store: store, context: .mockAny())
        harness.client.handler = { _ in
            .success((
                .mockResponseWith(statusCode: 200, headerFields: ["ETag": "\"server-stamped\""]),
                #"{ "schema_version": 1, "version": 42, "enabled": true, "rum": { "sessionSampleRate": 20 } }"#.data(using: .utf8)!
            ))
        }

        harness.controller.onSourcePublished(source)

        eventually(harness.recorder.published.count == 1)
        let stored = store.load(forKey: RemoteSamplingSnapshotStore.key(source: source, context: .mockAny()))
        XCTAssertEqual(stored?.version, 42)
        XCTAssertEqual(stored?.sessionSampleRate, 20)
        XCTAssertEqual(stored?.etag, "\"server-stamped\"", "the validator survives a restart so the next launch can revalidate")
    }

    // MARK: - Helpers

    private func makeStore() throws -> RemoteSamplingSnapshotStore {
        let directory = try Directory(url: temporaryDirectory).createSubdirectory(path: "remote-sampling-tests-\(UUID().uuidString)")
        return try RemoteSamplingSnapshotStore(
            coreDirectory: CoreDirectory(osDirectory: directory, coreDirectory: directory)
        )
    }
}
