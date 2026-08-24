/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import XCTest
import DatadogInternal
@testable import DatadogRUM
@testable import TestUtilities

class RUMDrawnConfigurationTests: XCTestCase {
    let writer = FileWriterMock()

    /// Owned by the test because `RUMSessionScope` holds its parent `unowned`: the mock's default
    /// parent is a temporary, and reading through it after it is released traps.
    private let parent = RUMContextProviderMock()

    private func context(rates: RemoteSamplingRates?) -> DatadogContext {
        var context: DatadogContext = .mockAny()
        context.set(additionalContext: rates)
        return context
    }

    // MARK: - Configuration URL

    func testConfigurationURLBuildsFromSiteIntake() throws {
        let context: DatadogContext = .mockWith(
            clientToken: "token-1",
            env: "prod",
            version: "1.2.3",
            sdkVersion: "2.3.4"
        )

        let url = try XCTUnwrap(remoteSamplingConfigurationURL(customEndpoint: nil, context: context))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertTrue(components.path.hasSuffix("/api/v2/rum/config"))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(query["client_token"], "token-1")
        XCTAssertEqual(query["sdk"], "ios")
        XCTAssertEqual(query["sdk_version"], "2.3.4")
        XCTAssertEqual(query["env"], "prod")
        XCTAssertEqual(query["app_version"], "1.2.3")
    }

    func testConfigurationURLBuildsNextToCustomEndpoint() throws {
        let url = try XCTUnwrap(remoteSamplingConfigurationURL(
            customEndpoint: URL(string: "https://custom.example.com/intake")!,
            context: .mockAny()
        ))

        XCTAssertEqual(url.host, "custom.example.com")
        XCTAssertTrue(url.path.hasSuffix("/intake/config"), "the configuration lives beside a custom intake")
    }

    // MARK: - Fetch trigger (session-driven, opt-in)

    func testWhenRemoteConfigurationEnabled_sessionCreationPublishesSource() {
        let featureScope = FeatureScopeMock()

        _ = RUMSessionScope.mockWith(
            context: context(rates: nil),
            dependencies: .mockWith(
                featureScope: featureScope,
                remoteConfigurationEnabled: true,
                customEndpoint: nil
            )
        )

        let source = featureScope.contextMock.additionalContext(ofType: RemoteSamplingSource.self)
        XCTAssertNotNil(source, "every session creation is one opportunity to fetch")
    }

    func testWhenRemoteConfigurationDisabled_sessionCreationPublishesNothing() {
        let featureScope = FeatureScopeMock()

        _ = RUMSessionScope.mockWith(
            context: context(rates: nil),
            dependencies: .mockWith(
                featureScope: featureScope,
                remoteConfigurationEnabled: false
            )
        )

        XCTAssertNil(
            featureScope.contextMock.additionalContext(ofType: RemoteSamplingSource.self),
            "opt-out means zero extra requests"
        )
    }

    // MARK: - Session draw

    func testSessionDrawUsesRemoteRateWhenSet() {
        let rejected = RUMSessionScope.mockWith(
            context: context(rates: RemoteSamplingRates(sessionSampleRate: 0)),
            dependencies: .mockWith(sessionSampler: .mockKeepAll())
        )
        XCTAssertFalse(rejected.isSampled, "the console's 0% wins over the init 100%")
        XCTAssertEqual(rejected.sessionUUID, .nullUUID)

        let kept = RUMSessionScope.mockWith(
            context: context(rates: RemoteSamplingRates(sessionSampleRate: 100)),
            dependencies: .mockWith(sessionSampler: .mockRejectAll())
        )
        XCTAssertTrue(kept.isSampled, "the console's 100% wins over the init 0%")
        XCTAssertNotEqual(kept.sessionUUID, .nullUUID)
    }

    func testSessionDrawKeepsInitRateWhenConsoleSetNone() {
        let scope = RUMSessionScope.mockWith(
            parent: parent,
            context: context(rates: RemoteSamplingRates(sessionSampleRate: nil, version: 42)),
            dependencies: .mockWith(sessionSampler: .mockRejectAll())
        )
        XCTAssertFalse(scope.isSampled, "absent means keep the init value, absent is not zero")
    }

    func testDrawRecordCarriesSessionConfiguration() {
        let scope = RUMSessionScope.mockWith(
            parent: parent,
            context: context(rates: RemoteSamplingRates(
                sessionSampleRate: 20,
                version: 42,
                custom: #"{"a":1}"#
            )),
            dependencies: .mockWith(sessionSampler: Sampler(samplingRate: 80))
        )

        let drawn = scope.drawnConfiguration
        XCTAssertEqual(drawn?.sessionSampleRate, 20)
        XCTAssertEqual(drawn?.version, 42)
        XCTAssertEqual(scope.context.drawnConfiguration, drawn, "the record flows down the scope chain")
    }

    func testDrawRecordResolvesInitRateFallback() {
        let scope = RUMSessionScope.mockWith(
            parent: parent,
            context: context(rates: RemoteSamplingRates(sessionSampleRate: nil)),
            dependencies: .mockWith(sessionSampler: Sampler(samplingRate: 80))
        )

        XCTAssertEqual(scope.drawnConfiguration?.sessionSampleRate, 80, "no console rate means the init rate is the drawn rate")
        XCTAssertEqual(scope.drawnConfiguration?.version, 0)
    }

    func testNoRemoteRatesMeansNoDrawRecord() {
        let scope = RUMSessionScope.mockWith(
            context: context(rates: nil),
            dependencies: .mockWith(sessionSampler: .mockKeepAll())
        )
        XCTAssertNil(scope.drawnConfiguration)
    }

    // MARK: - View event

    func testViewEventReportsDrawnConfiguration() throws {
        let rates = RemoteSamplingRates(
            sessionSampleRate: 20,
            version: 42
        )
        let sessionScope = RUMSessionScope.mockWith(
            parent: parent,
            context: context(rates: rates),
            dependencies: .mockWith(sessionSampler: Sampler(samplingRate: 80))
        )
        // ARC may release `sessionScope` at its last strong use, which is the line below — the view
        // scope's reference to it is unowned and would then dangle.
        defer { withExtendedLifetime(sessionScope) {} }
        let scope = RUMViewScope(
            isInitialView: true,
            parent: sessionScope,
            dependencies: .mockAny(),
            identity: .mockViewIdentifier(),
            path: "UIViewController",
            name: "ViewName",
            customTimings: [:],
            startTime: .mockAny(),
            serverTimeOffset: .zero,
            interactionToNextViewMetric: nil,
            viewIndexInSession: 0
        )

        _ = scope.process(command: RUMCommandMock(time: .mockAny()), context: .mockAny(), writer: writer)

        let event = try XCTUnwrap(writer.events(ofType: RUMViewEvent.self).first)
        XCTAssertEqual(event.dd.configuration?.sessionSampleRate, 20, "the drawn rate is reported, not the init one")
        XCTAssertEqual(event.dd.configuration?.rcVersion, 42, "the version the session was drawn with")
    }

    func testViewEventWithoutRemoteConfigurationReportsInitValuesAndNoVersion() throws {
        let sessionScope = RUMSessionScope.mockWith(
            parent: parent,
            context: context(rates: nil),
            dependencies: .mockWith(sessionSampler: Sampler(samplingRate: 80))
        )
        // ARC may release `sessionScope` at its last strong use, which is the line below — the view
        // scope's reference to it is unowned and would then dangle.
        defer { withExtendedLifetime(sessionScope) {} }
        let scope = RUMViewScope(
            isInitialView: true,
            parent: sessionScope,
            dependencies: .mockWith(sessionSampler: Sampler(samplingRate: 80)),
            identity: .mockViewIdentifier(),
            path: "UIViewController",
            name: "ViewName",
            customTimings: [:],
            startTime: .mockAny(),
            serverTimeOffset: .zero,
            interactionToNextViewMetric: nil,
            viewIndexInSession: 0
        )

        _ = scope.process(command: RUMCommandMock(time: .mockAny()), context: .mockAny(), writer: writer)

        let event = try XCTUnwrap(writer.events(ofType: RUMViewEvent.self).first)
        XCTAssertEqual(event.dd.configuration?.sessionSampleRate, 80)
        XCTAssertNil(event.dd.configuration?.rcVersion, "no remote configuration, no rc_version")
    }

    // MARK: - Encoding (fork patch)

    func testConfigurationEncodesRCVersion() throws {
        let configuration = RUMViewEvent.DD.Configuration(rcVersion: 42, sessionSampleRate: 100)

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any]
        )
        XCTAssertEqual(json["rc_version"] as? Int, 42)
        XCTAssertEqual(json["session_sample_rate"] as? Int, 100)

        // And it is absent when there is no remote configuration:
        let initOnly = RUMViewEvent.DD.Configuration(sessionSampleRate: 100)
        let initJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(initOnly)) as? [String: Any]
        )
        XCTAssertNil(initJSON["rc_version"])
    }
}
