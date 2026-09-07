/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import DatadogInternal
import TestUtilities
import XCTest
@testable import DatadogCore
@testable import DatadogRUM

/// Covers the wiring between the core and RUM, which no unit test reaches.
///
/// Everything here runs against a real `DatadogCore` rather than a mock or a proxy, because the
/// wiring under test is made of casts and callbacks that only the real core satisfies: RUM finds
/// the reader with `core as? RemoteSamplingReader`, and the single fetch trigger is
/// `DatadogCore.set(context:)` noticing a published `RemoteSamplingSource`. A test double stands
/// in for neither — with a proxy in place the whole feature goes quiet and every assertion below
/// still has to fail, which is the property that makes these tests worth having.
final class RemoteSamplingIntegrationTests: XCTestCase {
    private let applicationID = "app-id"
    private let customEndpoint = URL(string: "https://intake.example.com/api/v2/rum")!

    private var core: DatadogCore! // swiftlint:disable:this implicitly_unwrapped_optional
    private var httpClient: HTTPClientMock! // swiftlint:disable:this implicitly_unwrapped_optional
    private var directory: CoreDirectory! // swiftlint:disable:this implicitly_unwrapped_optional

    override func setUpWithError() throws {
        super.setUp()
        CreateTemporaryDirectory()
        directory = CoreDirectory(
            osDirectory: Directory(url: temporaryDirectory),
            coreDirectory: try Directory(url: temporaryDirectory).createSubdirectory(path: "core-\(UUID().uuidString)")
        )
        httpClient = HTTPClientMock(result: { _ in .success(.mockResponseWith(statusCode: 200)) })
        core = DatadogCore(
            directory: directory,
            dateProvider: SystemDateProvider(),
            initialConsent: .granted,
            performance: .mockAny(),
            httpClient: httpClient,
            encryption: nil,
            contextProvider: DatadogContextProvider(context: .mockWith(env: "prod", version: "1.0.0")),
            applicationVersion: "1.0.0",
            maxBatchesPerUpload: 1,
            backgroundTasksEnabled: false
        )
    }

    override func tearDown() {
        // The core keeps writing on its own queues; the directory cannot go until it has stopped.
        core?.flushAndTearDown()
        core = nil
        httpClient = nil
        directory = nil
        DeleteTemporaryDirectory()
        super.tearDown()
    }

    /// Records how the SDK drew each session, reported from the queue that draws them.
    ///
    /// The scopes themselves belong to the RUM command queue, so reading them from the test thread
    /// would be a data race — and this target runs under ThreadSanitizer, which says so. This
    /// listener is the supported way to watch a draw from outside.
    private final class DrawRecorder {
        @ReadWriteLock
        private(set) var collected: Bool?
        /// Every draw in order, which is what a test about sessions being REPLACED has to look at:
        /// the last decision alone cannot tell one session drawn twice from two sessions drawn once.
        @ReadWriteLock
        private(set) var draws: [Bool] = []
        var listener: RUM.SessionListener {
            { [self] _, isDiscarded in
                collected = !isDiscarded
                draws.append(!isDiscarded)
            }
        }
        // Wait on the COUNT and assert on the contents. Waiting on `draws == [x]` is a race with
        // itself: it is false both before the draw arrives and after the next one does, so a
        // loaded machine turns it into a flake rather than a failure that means something.
    }

    // MARK: - Helpers

    /// Writes a snapshot where this core will look for one, the way a previous launch would have.
    private func seedStoredSnapshot(_ snapshot: RemoteSamplingSnapshot) throws {
        let context = core.contextProvider.read()
        let url = try XCTUnwrap(remoteSamplingConfigurationURL(customEndpoint: customEndpoint, context: context))
        let key = RemoteSamplingSnapshotStore.key(source: .init(configurationURL: url), context: context)
        try RemoteSamplingSnapshotStore(coreDirectory: directory).save(snapshot, forKey: key)
    }

    private func enableRUM(
        sessionSampleRate: SampleRate,
        remoteConfigurationEnabled: Bool,
        onSessionStart: RUM.SessionListener? = nil
    ) {
        RUM.enable(
            with: RUM.Configuration(
                applicationID: applicationID,
                sessionSampleRate: sessionSampleRate,
                onSessionStart: onSessionStart,
                customEndpoint: customEndpoint,
                remoteConfigurationEnabled: remoteConfigurationEnabled
            ),
            in: core
        )
    }

    private var configRequests: [URLRequest] {
        httpClient.requestsSent().filter { $0.url?.path.hasSuffix("/config") == true }
    }

    /// Waits for `condition` while the visitor keeps interacting.
    ///
    /// A session ended by an arriving configuration is replaced lazily, on the next activity — and
    /// whether any single action lands before or after the change has been processed is a race.
    /// Poking repeatedly removes it without weakening what is asserted: one action after the change
    /// is enough, and this guarantees there is one.
    private func pokeUntil(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RUMMonitor.shared(in: core).addAction(type: .tap, name: "poke")
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    private func eventually(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    // MARK: - Tests

    func testTheStoredSnapshotDecidesTheFirstSessionOfTheLaunch() throws {
        // The whole reason the snapshot is on disk. The draw is synchronous and the context that
        // carries rates to features is not, so a launch that waited for the context would spend its
        // first session on the value the app was built with — and for many apps that is most of
        // their sessions.
        try seedStoredSnapshot(
            RemoteSamplingSnapshot(version: 9, etag: nil, enabled: true, sessionSampleRate: 100, custom: #"{"seeded":"yes"}"#)
        )

        // Initialised at 0: if the stored snapshot is not read before the draw, nothing is collected.
        let draws = DrawRecorder()
        enableRUM(sessionSampleRate: 0, remoteConfigurationEnabled: true, onSessionStart: draws.listener)

        eventually(draws.collected != nil, "a session is drawn when the SDK starts")
        XCTAssertEqual(draws.collected, true, "the stored 100 decided this session, not the 0 the app was built with")

        let reader = try XCTUnwrap(core as RemoteSamplingReader)
        XCTAssertEqual(reader.remoteSamplingRates?.version, 9, "and it came off disk, before any request could answer")
        XCTAssertEqual(reader.remoteSamplingRates?.sessionSampleRate, 100)
    }

    func testTheHostApplicationCanReadCustomValuesImmediatelyAfterEnable() throws {
        // Reading them to decide whether to force a session is what the API is documented for, and
        // that call happens at start-up — before any context broadcast could have arrived.
        try seedStoredSnapshot(
            RemoteSamplingSnapshot(version: 9, etag: nil, enabled: true, sessionSampleRate: 100, custom: #"{"seeded":"yes"}"#)
        )

        enableRUM(sessionSampleRate: 100, remoteConfigurationEnabled: true)

        let custom = try XCTUnwrap(RUMMonitor.shared(in: core).getRemoteConfig(), "seeded from the same read that primed the rates")
        XCTAssertEqual(custom["seeded"] as? String, "yes")
    }

    func testCreatingTheFirstSessionAsksTheConsoleExactlyOnce() throws {
        httpClient.fetchBody = #"{ "schema_version": 1, "version": 10, "enabled": true, "rum": { "sessionSampleRate": 25 } }"#
            .data(using: .utf8)!

        enableRUM(sessionSampleRate: 100, remoteConfigurationEnabled: true)

        eventually(self.configRequests.count == 1, "the session that starts with the SDK is one opportunity to fetch")

        let request = try XCTUnwrap(configRequests.first)
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "sdk" })?.value, "ios")
        XCTAssertEqual(query?.first(where: { $0.name == "env" })?.value, "prod")

        // And the answer reaches the rest of the SDK, which is the other half of the wiring.
        let reader = core as RemoteSamplingReader
        eventually(reader.remoteSamplingRates?.version == 10, "the answer is applied and published")
        XCTAssertEqual(reader.remoteSamplingRates?.sessionSampleRate, 25)

        // Nothing further goes out on its own: there is no timer behind this.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(configRequests.count, 1)
    }

    // MARK: - A change that arrives while a session is running

    /// The fetch a session's own creation triggers answers a moment later, while that session is
    /// still running. That is the only way a change reaches a client mid-flight, and what RUM does
    /// with it is decided across three components — controller, message bus, application scope.
    /// The unit tests pin the decision; these pin the wiring that delivers it.

    func testWhenTheRateRisesOffZero_theSessionDrawnAtZeroIsReplaced() throws {
        // An application the console alone ever turns on. Drawn at the stored 0 it collects
        // nothing, and nothing at all is indistinguishable from broken — so the arriving rate has
        // to reach the session that is already running.
        try seedStoredSnapshot(
            RemoteSamplingSnapshot(version: 1, etag: nil, enabled: true, sessionSampleRate: 0, custom: nil)
        )
        httpClient.fetchBody = #"{ "schema_version": 1, "version": 2, "enabled": true, "rum": { "sessionSampleRate": 100 } }"#
            .data(using: .utf8)!

        let draws = DrawRecorder()
        enableRUM(sessionSampleRate: 0, remoteConfigurationEnabled: true, onSessionStart: draws.listener)
        eventually(!draws.draws.isEmpty, "a session is drawn when the SDK starts")
        XCTAssertEqual(draws.draws.first, false, "the first session was drawn at the stored 0")

        // The session ends here; its replacement is drawn lazily, on the visitor's next activity.
        // Nothing is lost by that — a session with nobody in it has nothing to collect — but it
        // does mean collection begins at the next interaction rather than the instant the operator
        // moves the slider.
        eventually((core as RemoteSamplingReader).remoteSamplingRates?.sessionSampleRate == 100, "the 100 arrived")

        pokeUntil(draws.draws.count == 2, "the visitor's activity starts a session under the new rate")
        XCTAssertEqual(draws.draws.last, true, "drawn at the 100 the console just published, not the 0 it replaced")
    }

    func testWhenTheRateBecomesZero_theCollectedSessionStopsCollecting() throws {
        // "Stop collecting" is the one request where waiting for the session to rotate — which can
        // be hours — is the wrong answer.
        try seedStoredSnapshot(
            RemoteSamplingSnapshot(version: 1, etag: nil, enabled: true, sessionSampleRate: 100, custom: nil)
        )
        httpClient.fetchBody = #"{ "schema_version": 1, "version": 2, "enabled": true, "rum": { "sessionSampleRate": 0 } }"#
            .data(using: .utf8)!

        let draws = DrawRecorder()
        enableRUM(sessionSampleRate: 100, remoteConfigurationEnabled: true, onSessionStart: draws.listener)
        eventually(!draws.draws.isEmpty, "a session is drawn when the SDK starts")
        XCTAssertEqual(draws.draws.first, true, "it starts out collected, on the stored 100")

        // The session was ended; the next thing the visitor does starts one under the new rate.
        eventually((core as RemoteSamplingReader).remoteSamplingRates?.sessionSampleRate == 0, "the 0 arrived")

        pokeUntil(draws.draws.count == 2, "the visitor's activity starts a session under the new rate")
        XCTAssertEqual(draws.draws.last, false, "and it is not collected, because the console said 0")
    }

    func testWhenTheRateChangesToAnythingElse_theRunningSessionIsLeftAlone() throws {
        // The negative control for both tests above. Every other rate is silent about the session
        // already running: whether it "should" still be kept can only be answered by drawing
        // again, and drawing twice is not the same as drawing once — a fleet re-drawn on every
        // change would land nowhere near the rate that was set.
        try seedStoredSnapshot(
            RemoteSamplingSnapshot(version: 1, etag: nil, enabled: true, sessionSampleRate: 100, custom: nil)
        )
        httpClient.fetchBody = #"{ "schema_version": 1, "version": 2, "enabled": true, "rum": { "sessionSampleRate": 60 } }"#
            .data(using: .utf8)!

        let draws = DrawRecorder()
        enableRUM(sessionSampleRate: 100, remoteConfigurationEnabled: true, onSessionStart: draws.listener)

        eventually((core as RemoteSamplingReader).remoteSamplingRates?.sessionSampleRate == 60, "the change arrived")

        // Poked exactly as the `immediate` test is, and for the same reason: without activity this
        // would pass even if the session HAD been ended, because nothing would ever start its
        // replacement. With it, an ended session shows up as a second draw.
        for _ in 0..<10 {
            RUMMonitor.shared(in: core).addAction(type: .tap, name: "poke")
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertEqual(draws.draws, [true], "one session, drawn once, still running")
    }

    func testWhenTheConsoleAsksForImmediate_theRunningSessionIsReplacedWhateverTheRate() throws {
        // `immediate` carries no claim about what the new rates decide — only that the operator
        // does not want to wait. The rate here is one the tests above prove is otherwise silent.
        try seedStoredSnapshot(
            RemoteSamplingSnapshot(version: 1, etag: nil, enabled: true, sessionSampleRate: 100, custom: nil)
        )
        httpClient.fetchBody = #"""
        { "schema_version": 1, "version": 2, "enabled": true, "activation": "immediate", "rum": { "sessionSampleRate": 60 } }
        """#.data(using: .utf8)!

        let draws = DrawRecorder()
        enableRUM(sessionSampleRate: 100, remoteConfigurationEnabled: true, onSessionStart: draws.listener)
        eventually(!draws.draws.isEmpty, "a session is drawn when the SDK starts")
        XCTAssertEqual(draws.draws.first, true, "a collected session is running")

        eventually((core as RemoteSamplingReader).remoteSamplingRates?.sessionSampleRate == 60, "the change arrived")

        // 60 on its own would have left this session alone — `testWhenTheRateChangesToAnythingElse`
        // is that same rate with the same seed, poked the same way. The only difference is the
        // console asking.
        pokeUntil(draws.draws.count == 2, "the console asked for the change to land now")
    }

    func testAForcedSessionIsNotEndedByAChangeThatWouldOtherwiseEndIt() throws {
        // Forcing exists to watch one visitor. Ending their session buys an identical forced one,
        // with the view they were on lost from the recording somebody turned forcing on to see.
        //
        // The ordering is built rather than hoped for. The first answer repeats what is already
        // stored, so nothing changes and no session is touched; the changed answer is only put in
        // place afterwards, which means the fetch that carries it is the one the FORCED session's
        // own creation triggers. Forcing is therefore in effect before the change can arrive —
        // otherwise this test would sometimes be measuring the opposite race.
        try seedStoredSnapshot(
            RemoteSamplingSnapshot(version: 1, etag: nil, enabled: true, sessionSampleRate: 0, custom: nil)
        )
        httpClient.fetchBody = #"{ "schema_version": 1, "version": 1, "enabled": true, "rum": { "sessionSampleRate": 0 } }"#
            .data(using: .utf8)!

        let draws = DrawRecorder()
        enableRUM(sessionSampleRate: 0, remoteConfigurationEnabled: true, onSessionStart: draws.listener)
        eventually(!draws.draws.isEmpty, "a session is drawn when the SDK starts")
        eventually(self.configRequests.count == 1, "and it asked, receiving what it already had")

        // Both reasons to end a session are in this one: an explicit `immediate`, and a rate of
        // zero. Forcing answers no to both.
        httpClient.fetchBody = #"""
        { "schema_version": 1, "version": 2, "enabled": true, "activation": "immediate", "rum": { "sessionSampleRate": 0 } }
        """#.data(using: .utf8)!

        RUMMonitor.shared(in: core).setForcedSession()
        // Lazily, like every other replacement here: the session ends now and the next one is
        // drawn when the visitor does something.
        pokeUntil(draws.draws.count == 2, "forcing replaces the session that was not being collected")
        XCTAssertEqual(draws.draws.last, true, "and its replacement is collected")

        eventually((core as RemoteSamplingReader).remoteSamplingRates?.version == 2, "the change arrived, fetched by the forced session")
        for _ in 0..<10 {
            RUMMonitor.shared(in: core).addAction(type: .tap, name: "poke")
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertEqual(draws.draws, [false, true], "the forced session keeps running")
    }

    func testAnUnchangedConfigurationArrivingAgainDoesNotChurnSessions() throws {
        // Every session creation asks again, and most answers repeat what is already in force. If
        // a repeat could end a session, an idle app would cut itself in two on every rotation,
        // forever.
        try seedStoredSnapshot(
            RemoteSamplingSnapshot(version: 2, etag: nil, enabled: true, sessionSampleRate: 100, custom: nil)
        )
        httpClient.fetchBody = #"{ "schema_version": 1, "version": 2, "enabled": true, "rum": { "sessionSampleRate": 100 } }"#
            .data(using: .utf8)!

        let draws = DrawRecorder()
        enableRUM(sessionSampleRate: 100, remoteConfigurationEnabled: true, onSessionStart: draws.listener)

        eventually(self.configRequests.count == 1, "the session asked")
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(draws.draws, [true], "the same values arriving again change nothing")
    }

    func testAnApplicationThatDidNotOptInNeverAsks() throws {
        // The guarantee the default rests on. A stored snapshot is deliberately present, so this
        // fails if the feature reads one without being asked to.
        try seedStoredSnapshot(
            RemoteSamplingSnapshot(version: 9, etag: nil, enabled: true, sessionSampleRate: 0, custom: #"{"seeded":"yes"}"#)
        )

        let draws = DrawRecorder()
        enableRUM(sessionSampleRate: 100, remoteConfigurationEnabled: false, onSessionStart: draws.listener)

        eventually(draws.collected != nil, "a session is drawn when the SDK starts")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(configRequests.count, 0, "no request is made")
        XCTAssertNil(RUMMonitor.shared(in: core).getRemoteConfig(), "and nothing is read from disk")
        XCTAssertNil((core as RemoteSamplingReader).remoteSamplingRates, "no controller is ever built")
        XCTAssertEqual(draws.collected, true, "the session is drawn at the value the app was built with")
    }
}
