/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import XCTest
import DatadogInternal
@testable import DatadogRUM
@testable import TestUtilities

/// Records each request and answers it when the test says so.
private final class DirectRequestSenderMock: DirectRequestSender {
    private(set) var requests: [URLRequest] = []
    private var completions: [(Result<HTTPURLResponse, Error>) -> Void] = []

    func sendDirectly(request: URLRequest, completion: @escaping (Result<HTTPURLResponse, Error>) -> Void) {
        requests.append(request)
        completions.append(completion)
    }

    var inFlight: Int { completions.count }

    func respond(_ statusCode: Int) {
        guard !completions.isEmpty else {
            return XCTFail("no request is waiting for an answer")
        }
        let response = HTTPURLResponse(url: URL(string: "https://intake.test")!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        completions.removeFirst()(.success(response))
    }

    func fail() {
        guard !completions.isEmpty else {
            return XCTFail("no request is waiting for an answer")
        }
        completions.removeFirst()(.failure(ErrorMock("offline")))
    }

    func body(_ index: Int) throws -> [String: Any] {
        guard requests.indices.contains(index) else {
            throw ErrorMock("no request #\(index) was sent")
        }
        let data = try XCTUnwrap(requests[index].httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

/// A data store whose reads are answered only when the test says so, as a read from disk may
/// return after the first context updates.
private final class DeferredDataStore: DataStore {
    let store: DataStoreMock
    private var reads: [() -> Void] = []

    init(_ store: DataStoreMock) {
        self.store = store
    }

    func setValue(_ value: Data, forKey key: String, version: DataStoreKeyVersion) { store.setValue(value, forKey: key, version: version) }
    func value(forKey key: String, callback: @escaping (DataStoreValueResult) -> Void) {
        let result = store.value(forKey: key) ?? .noValue // what the disk held when the read began
        reads.append { callback(result) }
    }
    func removeValue(forKey key: String) { store.removeValue(forKey: key) }
    func clearAllData() { store.clearAllData() }
    func flush() {}

    func answerReads() {
        while !reads.isEmpty {
            reads.removeFirst()()
        }
    }
}

/// `FeatureScopeMock` with its data store replaced.
private final class DataStoreReplacingScope: FeatureScope, @unchecked Sendable {
    let scope: FeatureScopeMock
    let dataStore: DataStore

    init(_ scope: FeatureScopeMock, dataStore: DataStore) {
        self.scope = scope
        self.dataStore = dataStore
    }

    var telemetry: Telemetry { scope.telemetry }
    func eventWriteContext(bypassConsent: Bool, _ block: @escaping (DatadogContext, Writer) -> Void) { scope.eventWriteContext(bypassConsent: bypassConsent, block) }
    func context(_ block: @escaping (DatadogContext) -> Void) { scope.context(block) }
    func send(message: FeatureMessage, else fallback: @escaping () -> Void) { scope.send(message: message, else: fallback) }
    func set<Context>(context: @escaping () -> Context?) where Context: AdditionalContext { scope.set(context: context) }
    func set(anonymousId: String?) { scope.set(anonymousId: anonymousId) }
}

class ActiveDeviceBeaconTests: XCTestCase {
    private let anonymousId = "a1b2c3d4-0000-4000-8000-000000000001"
    private let featureScope = FeatureScopeMock()
    private let sender = DirectRequestSenderMock()
    private var scheduled: [() -> Void] = []
    /// Local noon, so moving by minutes or hours never crosses a day.
    private let dateProvider = DateProviderMock(
        now: Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_800_000_000))!
    )

    private func makeBeacon(customEndpoint: URL? = nil, trackAnonymousUser: Bool = true) -> ActiveDeviceBeacon {
        ActiveDeviceBeacon(
            featureScope: featureScope,
            sender: sender,
            customEndpoint: customEndpoint,
            trackAnonymousUser: trackAnonymousUser,
            dateProvider: dateProvider,
            retryDelays: [2, 8],
            schedule: { [unowned self] _, work in self.scheduled.append(work) }
        )
    }

    private lazy var beacon = makeBeacon()

    private func context(
        consent: TrackingConsent = .granted,
        state: AppState = .active,
        bundleType: BundleType = .iOSApp,
        anonymousId: String?? = .none,
        userId: String? = nil,
        service: String = "shop-ios",
        version: String = "1.2.3",
        buildNumber: String = "42"
    ) -> DatadogContext {
        .mockWith(
            site: .cn,
            clientToken: "pub-token",
            service: service,
            env: "prod",
            version: version,
            buildNumber: buildNumber,
            sdkVersion: "0.9.0",
            applicationBundleType: bundleType,
            device: .mockWith(model: "iPhone15,2"),
            os: .mockWith(name: "iOS", version: "18.2.1"),
            userInfo: UserInfo(anonymousId: anonymousId ?? self.anonymousId, id: userId),
            trackingConsent: consent,
            applicationStateHistory: .mockWith(initialState: state, date: dateProvider.now)
        )
    }

    /// Delivers a context update and waits for the beacon to act on it.
    private func publish(_ context: DatadogContext) {
        XCTAssertFalse(beacon.receive(message: .context(context), from: NOPDatadogCore()), "context updates are broadcast, not claimed")
        drain()
    }

    private func drain() {
        beacon.queue.sync {}
    }

    private func respond(_ statusCode: Int) {
        sender.respond(statusCode)
        drain()
    }

    private func fail() {
        sender.fail()
        drain()
    }

    private func runScheduledRetry() {
        guard !scheduled.isEmpty else {
            return XCTFail("no retry is scheduled")
        }
        scheduled.removeFirst()()
        drain()
    }

    private var storedPending: DataStoreValueResult? {
        featureScope.dataStoreMock.value(forKey: RUMDataStore.Key.activeBeaconPending.rawValue)
    }

    private var storedSent: DataStoreValueResult? {
        featureScope.dataStoreMock.value(forKey: RUMDataStore.Key.activeBeaconSent.rawValue)
    }

    private func storePending(usedAt: Date, key: String = "2000-01-01|stored|") {
        let body = ActiveDeviceBeacon.Body(
            service: "shop-ios",
            env: "prod",
            version: "1.2.2",
            buildVersion: "41",
            sdkVersion: "0.8.0",
            usr: .init(anonymousId: anonymousId, id: nil),
            os: .init(name: "iOS", version: "18.2.1"),
            device: .init(type: "mobile", model: "iPhone15,2", brand: "Apple"),
            ageMs: 0
        )
        featureScope.rumDataStore.setValue(ActiveDeviceBeacon.Record(body: body, usedAt: usedAt, key: key), forKey: .activeBeaconPending)
    }

    // MARK: - Request

    func testItSendsTheContractBodyToTheIntake() throws {
        publish(context())

        XCTAssertEqual(sender.requests.count, 1)
        let request = sender.requests[0]
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://browser.flashcat.cloud/api/v2/rum/active?dd-api-key=pub-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Content-Encoding"), "the intake reads it uncompressed")

        let body = try sender.body(0)
        XCTAssertEqual(body["service"] as? String, "shop-ios")
        XCTAssertEqual(body["env"] as? String, "prod")
        XCTAssertEqual(body["version"] as? String, "1.2.3")
        XCTAssertEqual(body["build_version"] as? String, "42")
        XCTAssertEqual(body["sdk_version"] as? String, "0.9.0")
        XCTAssertEqual(body["usr"] as? [String: String], ["anonymous_id": anonymousId])
        XCTAssertEqual(body["os"] as? [String: String], ["name": "iOS", "version": "18.2.1"])
        XCTAssertEqual(body["device"] as? [String: String], ["type": "mobile", "model": "iPhone15,2", "brand": "Apple"])
        XCTAssertEqual(body["age_ms"] as? Int, 0)
    }

    func testItSendsBesideACustomEndpoint() {
        beacon = makeBeacon(customEndpoint: URL(string: "https://rum.example.com/intake/rum")!)
        publish(context())

        XCTAssertEqual(sender.requests.first?.url?.absoluteString, "https://rum.example.com/intake/rum/active?dd-api-key=pub-token")
    }

    func testItCutsEveryStringFieldTo255Bytes() throws {
        publish(context(userId: String(repeating: "u", count: 300), service: String(repeating: "服", count: 100)))

        let body = try sender.body(0)
        XCTAssertEqual((body["usr"] as? [String: String])?["id"], String(repeating: "u", count: 255))
        XCTAssertEqual(body["service"] as? String, String(repeating: "服", count: 85), "85 three-byte characters fit, the 86th does not")

        XCTAssertEqual(ActiveDeviceBeacon.cut(String(repeating: "a", count: 253) + "👍🏽"), String(repeating: "a", count: 253), "an emoji is not split")
        XCTAssertEqual(ActiveDeviceBeacon.cut("short"), "short")
    }

    // MARK: - Triggers

    func testAtLaunch_itWaitsForTheAnonymousIdToBeRead() {
        publish(context(anonymousId: .some(nil), userId: "user-1"))
        XCTAssertEqual(sender.requests.count, 0, "the anonymous id is read from disk after start; a user id alone is not enough")

        publish(context(userId: "user-1"))
        XCTAssertEqual(sender.requests.count, 1)
    }

    func testWithAnonymousTrackingOff_itWaitsForAUserId() throws {
        beacon = makeBeacon(trackAnonymousUser: false)
        publish(context(anonymousId: .some(nil)))
        XCTAssertEqual(sender.requests.count, 0)

        publish(context(anonymousId: .some(nil), userId: "user-1"))
        XCTAssertEqual(sender.requests.count, 1)
        XCTAssertEqual(try sender.body(0)["usr"] as? [String: String], ["id": "user-1"])
    }

    func testABackgroundLaunchDoesNotSend_untilTheAppComesToTheForeground() {
        publish(context(state: .background))
        publish(context(state: .inactive))
        XCTAssertEqual(sender.requests.count, 0)
        XCTAssertNil(storedPending)

        publish(context(state: .active))
        XCTAssertEqual(sender.requests.count, 1)
    }

    func testAnAppExtensionNeverSends() {
        publish(context(bundleType: .iOSAppExtension))
        XCTAssertEqual(sender.requests.count, 0)
    }

    func testItSendsOncePerLocalDay() {
        publish(context())
        respond(202)
        publish(context(state: .background))
        dateProvider.now.addTimeInterval(3_600)
        publish(context(state: .active))
        XCTAssertEqual(sender.requests.count, 1, "returning to the foreground the same day sends nothing")

        dateProvider.now.addTimeInterval(24 * 3_600)
        publish(context(state: .active))
        XCTAssertEqual(sender.requests.count, 2, "the next day is reported")
    }

    func testANewDayIsReportedWhileTheAppStaysInTheForeground() {
        publish(context())
        respond(202)

        dateProvider.now.addTimeInterval(24 * 3_600)
        publish(context()) // any context update after midnight
        XCTAssertEqual(sender.requests.count, 2)
    }

    func testTheSentMarkerSurvivesARelaunch() {
        publish(context())
        respond(202)

        beacon = makeBeacon() // a new process, same data store
        publish(context())
        XCTAssertEqual(sender.requests.count, 1)
    }

    func testAnUpgradeTheSameDayIsReportedForTheNewVersion() throws {
        publish(context())
        respond(202)

        beacon = makeBeacon() // the upgraded app's first launch, same day, same identity
        publish(context(version: "1.2.4", buildNumber: "43"))
        XCTAssertEqual(sender.requests.count, 2, "the new version is reported")
        XCTAssertEqual(try sender.body(1)["version"] as? String, "1.2.4")
        XCTAssertEqual(try sender.body(1)["build_version"] as? String, "43")
        respond(202)

        beacon = makeBeacon() // relaunched again on the same version
        publish(context(version: "1.2.4", buildNumber: "43"))
        XCTAssertEqual(sender.requests.count, 2, "the same version is not reported twice a day")
    }

    func testANewBuildOfTheSameVersionIsReportedTheSameDay() {
        publish(context())
        respond(202)

        beacon = makeBeacon()
        publish(context(buildNumber: "43"))
        XCTAssertEqual(sender.requests.count, 2)
    }

    func testANewUserIsReportedTheSameDay() throws {
        publish(context())
        respond(202)

        publish(context(userId: "user-1"))
        XCTAssertEqual(sender.requests.count, 2, "setUserInfo")
        XCTAssertEqual((try sender.body(1)["usr"] as? [String: String])?["id"], "user-1")
        respond(202)

        publish(context(userId: nil))
        XCTAssertEqual(sender.requests.count, 3, "clearUserInfo")
    }

    func testAUserSetWhileTheLaunchBeaconIsOnTheWireIsNotLost() {
        publish(context())
        publish(context(userId: "user-1"))
        XCTAssertEqual(sender.requests.count, 1, "one request at a time")

        respond(202)
        XCTAssertEqual(sender.requests.count, 2)
    }

    // MARK: - Consent

    func testPendingConsentNeitherSendsNorStores_untilItIsGranted() {
        publish(context(consent: .pending))
        XCTAssertEqual(sender.requests.count, 0)
        XCTAssertNil(storedPending)
        XCTAssertNil(storedSent)

        publish(context(consent: .granted))
        XCTAssertEqual(sender.requests.count, 1)
    }

    func testWithdrawnConsentDeletesWhatIsStored() {
        publish(context())
        respond(202)
        publish(context(userId: "user-1"))
        fail()
        runScheduledRetry()
        respond(503)
        runScheduledRetry()
        respond(503)
        XCTAssertNotNil(storedPending)
        XCTAssertNotNil(storedSent)

        publish(context(consent: .notGranted, userId: "user-1"))
        XCTAssertNil(storedPending)
        XCTAssertNil(storedSent)

        publish(context(consent: .granted, userId: "user-1"))
        XCTAssertEqual(sender.requests.count, 5, "granted again: today is reported anew")
        XCTAssertEqual(try sender.body(4)["age_ms"] as? Int, 0)
    }

    func testConsentWithdrawnDuringAnInFlightRequestWritesNothing() {
        publish(context())
        publish(context(consent: .notGranted))
        respond(202)

        XCTAssertNil(storedSent, "no sent marker once consent is withdrawn")
        XCTAssertNil(storedPending)
    }

    func testConsentWithdrawnDuringTheBackoffStopsTheRetries() {
        publish(context())
        fail()
        publish(context(consent: .notGranted))
        runScheduledRetry()

        XCTAssertEqual(sender.requests.count, 1)
        XCTAssertNil(storedPending)
    }

    func testConsentWithdrawnAndGrantedAgainDuringARequest_onlyTheNewGrantIsReported() throws {
        publish(context())
        publish(context(consent: .notGranted))
        publish(context(consent: .granted))
        XCTAssertEqual(sender.requests.count, 1, "one request at a time")

        respond(202)
        XCTAssertEqual(sender.requests.count, 2, "the grant is reported with a beacon of its own")
        respond(202)
        XCTAssertNil(storedPending)
    }

    func testConsentWithdrawnAndGrantedAgainDuringTheBackoff_theDroppedBeaconIsNotRetried() {
        dateProvider.now.addTimeInterval(-60)
        publish(context())
        fail()
        dateProvider.now.addTimeInterval(60)
        publish(context(consent: .notGranted))
        publish(context(consent: .granted))
        runScheduledRetry()

        XCTAssertEqual(sender.requests.count, 2)
        XCTAssertEqual(try sender.body(1)["age_ms"] as? Int, 0, "a new beacon, not the one dropped at the withdrawal")
    }

    func testConsentWithdrawnAndGrantedAgainBeforeTheStoredValuesAreRead_theyDoNotComeBack() {
        publish(context())
        respond(202) // a previous launch reported today
        XCTAssertNotNil(storedSent)

        let dataStore = DeferredDataStore(featureScope.dataStoreMock)
        beacon = ActiveDeviceBeacon(
            featureScope: DataStoreReplacingScope(featureScope, dataStore: dataStore),
            sender: sender,
            customEndpoint: nil,
            trackAnonymousUser: true,
            dateProvider: dateProvider
        )
        publish(context(consent: .notGranted))
        publish(context(consent: .granted))
        XCTAssertNil(storedSent, "deleted at the withdrawal")

        dataStore.answerReads() // the read began before the withdrawal
        drain()

        XCTAssertEqual(sender.requests.count, 2, "the grant is reported: the deleted marker does not suppress it")
    }

    func testConsentBackToPendingDuringARequestWritesNoSentMarker() {
        publish(context())
        publish(context(consent: .pending))
        respond(202)

        XCTAssertNil(storedSent)
    }

    // MARK: - Failures

    func testItRetriesTwiceThenKeepsTheBeaconAndSendsItLaterWithItsAge() throws {
        publish(context())
        fail()
        XCTAssertNotNil(storedPending, "stored before the first retry, in case the process does not survive it")
        runScheduledRetry()
        respond(500)
        runScheduledRetry()
        respond(429)
        XCTAssertEqual(sender.requests.count, 3)
        XCTAssertTrue(scheduled.isEmpty, "no third retry")

        publish(context(service: "updated")) // not a trigger: nothing it depends on changed
        XCTAssertEqual(sender.requests.count, 3)

        publish(context(state: .background))
        dateProvider.now.addTimeInterval(3_600)
        publish(context(state: .active))
        XCTAssertEqual(sender.requests.count, 4)
        XCTAssertEqual(try sender.body(3)["age_ms"] as? Int, 3_600_000)
        XCTAssertEqual(try sender.body(3)["service"] as? String, "shop-ios", "the body of the moment the app was in use")

        respond(202)
        XCTAssertNil(storedPending)
        XCTAssertEqual(sender.requests.count, 4, "today was the stored one")
    }

    func testABeaconStoredByAnEarlierLaunchIsSentFirst_thenToday() throws {
        storePending(usedAt: dateProvider.now.addingTimeInterval(-30 * 3_600))
        publish(context())

        XCTAssertEqual(try sender.body(0)["age_ms"] as? Int, 30 * 3_600_000)
        respond(202)
        XCTAssertEqual(sender.requests.count, 2)
        XCTAssertEqual(try sender.body(1)["age_ms"] as? Int, 0)
    }

    func testABeaconOlderThan72HoursIsDropped() throws {
        storePending(usedAt: dateProvider.now.addingTimeInterval(-73 * 3_600))
        publish(context())

        XCTAssertEqual(sender.requests.count, 1)
        XCTAssertEqual(try sender.body(0)["age_ms"] as? Int, 0, "only today's beacon is sent")
    }

    func testARateLimitIsRetried() {
        publish(context())
        respond(429)

        XCTAssertEqual(scheduled.count, 1)
        runScheduledRetry()
        XCTAssertEqual(sender.requests.count, 2)
    }

    func testAnIntakeWithoutTheEndpointKeepsTheBeaconForLater() throws {
        publish(context())
        respond(404)
        runScheduledRetry()
        respond(404)
        runScheduledRetry()
        respond(404)
        XCTAssertNotNil(storedPending, "kept until the intake serves the endpoint")

        publish(context(state: .background))
        dateProvider.now.addTimeInterval(3_600)
        publish(context(state: .active))
        XCTAssertEqual(sender.requests.count, 4)
        XCTAssertEqual(try sender.body(3)["age_ms"] as? Int, 3_600_000)
    }

    func testAClientErrorIsNotRetriedOrKept() {
        publish(context())
        respond(400)

        XCTAssertTrue(scheduled.isEmpty)
        XCTAssertNil(storedPending)

        publish(context(state: .background))
        publish(context(state: .active))
        XCTAssertEqual(sender.requests.count, 1, "the same body would be refused again today")
    }

    func testGoingToTheBackgroundDuringTheBackoffKeepsTheBeaconForTheNextForeground() {
        publish(context())
        fail()
        publish(context(state: .background))
        runScheduledRetry()
        XCTAssertEqual(sender.requests.count, 1)
        XCTAssertNotNil(storedPending)

        publish(context(state: .active))
        XCTAssertEqual(sender.requests.count, 2)
    }
}

// MARK: - Feature wiring

/// A core that sends direct requests, as `DatadogCore` does.
private final class DirectSendingCoreMock: PassthroughCoreMock, DirectRequestSender {
    var onSend: ((URLRequest) -> Void)?

    func sendDirectly(request: URLRequest, completion: @escaping (Result<HTTPURLResponse, Error>) -> Void) {
        onSend?(request)
    }
}

class ActiveDeviceBeaconFeatureTests: XCTestCase {
    private let activeContext: DatadogContext = .mockWith(
        applicationBundleType: .iOSApp,
        userInfo: UserInfo(anonymousId: "a1b2c3d4-0000-4000-8000-000000000001"),
        trackingConsent: .granted,
        applicationStateHistory: .mockAppInForeground()
    )

    func testItSendsEvenWhenTheSessionIsSampledOut() throws {
        let core = DirectSendingCoreMock(context: activeContext, dataStore: DataStoreMock())
        let sent = expectation(description: "beacon sent")
        core.onSend = { _ in sent.fulfill() }
        let rum = try RUMFeature(in: core, configuration: .mockWith { $0.sessionSampleRate = 0 })
        core.messageReceiver = rum.messageReceiver
        defer { core.messageReceiver = NOPFeatureMessageReceiver() } // the feature's receivers hold the core

        core.context = activeContext

        wait(for: [sent], timeout: 2)
    }

    func testTheToggleOffSendsNothingAndDeletesWhatIsStored() throws {
        let dataStore = DataStoreMock()
        dataStore.storage = [
            RUMDataStore.Key.activeBeaconSent.rawValue: .value(Data("\"key\"".utf8), dataStoreDefaultKeyVersion),
            RUMDataStore.Key.activeBeaconPending.rawValue: .value(Data("{}".utf8), dataStoreDefaultKeyVersion)
        ]
        let core = DirectSendingCoreMock(context: activeContext, dataStore: dataStore)
        let sent = expectation(description: "beacon sent")
        sent.isInverted = true
        core.onSend = { _ in sent.fulfill() }
        let rum = try RUMFeature(in: core, configuration: .mockWith { $0.trackActiveDevices = false })
        core.messageReceiver = rum.messageReceiver
        defer { core.messageReceiver = NOPFeatureMessageReceiver() } // the feature's receivers hold the core

        core.context = activeContext

        wait(for: [sent], timeout: 0.5)
        XCTAssertNil(dataStore.value(forKey: RUMDataStore.Key.activeBeaconSent.rawValue))
        XCTAssertNil(dataStore.value(forKey: RUMDataStore.Key.activeBeaconPending.rawValue))
    }
}
