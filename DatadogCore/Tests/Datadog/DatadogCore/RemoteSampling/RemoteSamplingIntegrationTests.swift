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
        @ReadWriteLock private(set) var collected: Bool?
        var listener: RUM.SessionListener { { [self] _, isDiscarded in collected = !isDiscarded } }
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
