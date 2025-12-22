/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import XCTest
import TestUtilities

@testable import FlashcatInternal
@testable import FlashcatLogs
@testable import FlashcatTrace
@testable import FlashcatCore

class DatadogTests: XCTestCase {
    private var printFunction: PrintFunctionSpy! // swiftlint:disable:this implicitly_unwrapped_optional
    private var defaultConfig = Flashcat.Configuration(clientToken: "abc-123", env: "tests")

    override func setUp() {
        super.setUp()

        XCTAssertFalse(Flashcat.isInitialized())
        printFunction = PrintFunctionSpy()
        consolePrint = printFunction.print
    }

    override func tearDown() {
        consolePrint = { message, _ in print(message) }
        printFunction = nil
        XCTAssertFalse(Flashcat.isInitialized())
        super.tearDown()
    }

    // MARK: - Initializing with different configurations

    func testDefaultConfiguration() throws {
        var configuration = defaultConfig

        configuration.bundle = .mockWith(
            bundleIdentifier: "test",
            CFBundleShortVersionString: "1.0.0",
            CFBundleExecutable: "Test"
        )

        XCTAssertEqual(configuration.batchSize, .medium)
        XCTAssertEqual(configuration.uploadFrequency, .average)
        XCTAssertEqual(configuration.additionalConfiguration.count, 0)
        XCTAssertNil(configuration.encryption)
        XCTAssertTrue(configuration.serverDateProvider is DatadogNTPDateProvider)

        Flashcat.initialize(
            with: configuration,
            trackingConsent: .granted
        )
        defer { Flashcat.flushAndDeinitialize() }

        let core = try XCTUnwrap(CoreRegistry.default as? FlashcatCore)
        let urlSessionClient = try XCTUnwrap(core.httpClient as? URLSessionClient)
        XCTAssertTrue(core.dateProvider is SystemDateProvider)
        XCTAssertNil(urlSessionClient.session.configuration.connectionProxyDictionary)
        XCTAssertNil(core.encryption)

        let context = core.contextProvider.read()
        XCTAssertEqual(context.clientToken, "abc-123")
        XCTAssertEqual(context.env, "tests")
        XCTAssertEqual(context.site, .cn)
        XCTAssertEqual(context.service, "test")
        XCTAssertEqual(context.version, "1.0.0")
        XCTAssertEqual(context.sdkVersion, __sdkVersion)
        XCTAssertEqual(context.applicationName, "Test")
        XCTAssertNil(context.variant)
        XCTAssertEqual(context.source, "ios")
        XCTAssertEqual(context.applicationBundleIdentifier, "test")
        XCTAssertEqual(context.trackingConsent, .granted)
    }

    func testAdvancedConfiguration() throws {
        var configuration = defaultConfig

        configuration.service = "service-name"
        configuration.site = .staging
        configuration.batchSize = .small
        configuration.uploadFrequency = .frequent
        configuration.proxyConfiguration = [
            kCFNetworkProxiesHTTPEnable: true,
            kCFNetworkProxiesHTTPPort: 123,
            kCFNetworkProxiesHTTPProxy: "www.example.com",
            kCFProxyUsernameKey: "proxyuser",
            kCFProxyPasswordKey: "proxypass",
        ]
        configuration.bundle = .mockWith(
            bundleIdentifier: "test",
            CFBundleShortVersionString: "1.0.0",
            CFBundleExecutable: "Test"
        )
        configuration.encryption = DataEncryptionMock()
        configuration.serverDateProvider = ServerDateProviderMock()
        configuration._internal_mutation {
            $0.additionalConfiguration = [
                CrossPlatformAttributes.ddsource: "cp-source",
                CrossPlatformAttributes.variant: "cp-variant",
                CrossPlatformAttributes.sdkVersion: "cp-version"
            ]
        }

        XCTAssertEqual(configuration.batchSize, .small)
        XCTAssertEqual(configuration.uploadFrequency, .frequent)
        XCTAssertTrue(configuration.encryption is DataEncryptionMock)
        XCTAssertTrue(configuration.serverDateProvider is ServerDateProviderMock)

        Flashcat.initialize(
            with: configuration,
            trackingConsent: .pending
        )
        defer { Flashcat.flushAndDeinitialize() }

        let core = try XCTUnwrap(CoreRegistry.default as? FlashcatCore)
        XCTAssertTrue(core.dateProvider is SystemDateProvider)
        XCTAssertTrue(core.encryption is DataEncryptionMock)

        let urlSessionClient = try XCTUnwrap(core.httpClient as? URLSessionClient)
        let connectionProxyDictionary = try XCTUnwrap(urlSessionClient.session.configuration.connectionProxyDictionary)
        XCTAssertEqual(connectionProxyDictionary[kCFNetworkProxiesHTTPEnable] as? Bool, true)
        XCTAssertEqual(connectionProxyDictionary[kCFNetworkProxiesHTTPPort] as? Int, 123)
        XCTAssertEqual(connectionProxyDictionary[kCFNetworkProxiesHTTPProxy] as? String, "www.example.com")
        XCTAssertEqual(connectionProxyDictionary[kCFProxyUsernameKey] as? String, "proxyuser")
        XCTAssertEqual(connectionProxyDictionary[kCFProxyPasswordKey] as? String, "proxypass")

        let context = core.contextProvider.read()
        XCTAssertEqual(context.clientToken, "abc-123")
        XCTAssertEqual(context.env, "tests")
        XCTAssertEqual(context.site, .staging)
        XCTAssertEqual(context.service, "service-name")
        XCTAssertEqual(context.version, "1.0.0")
        XCTAssertEqual(context.sdkVersion, "cp-version")
        XCTAssertEqual(context.applicationName, "Test")
        XCTAssertEqual(context.variant, "cp-variant")
        XCTAssertEqual(context.source, "cp-source")
        XCTAssertEqual(context.applicationBundleIdentifier, "test")
        XCTAssertEqual(context.trackingConsent, .pending)
    }

    func testGivenDefaultConfiguration_itCanBeInitialized() {
        Flashcat.initialize(
            with: defaultConfig,
            trackingConsent: .mockRandom()
        )
        XCTAssertTrue(Flashcat.isInitialized())
        Flashcat.flushAndDeinitialize()
    }

    func testGivenInvalidConfiguration_itPrintsError() {
        let invalidConfiguration = Flashcat.Configuration(clientToken: "", env: "tests")

        Flashcat.initialize(
            with: invalidConfiguration,
            trackingConsent: .mockRandom()
        )

        XCTAssertEqual(
            printFunction.printedMessage,
            "🔥 Datadog SDK usage error: `clientToken` cannot be empty."
        )
        XCTAssertFalse(Flashcat.isInitialized())
    }

    func testGivenValidConfiguration_whenInitializedMoreThanOnce_itPrintsError() {
        Flashcat.initialize(
            with: defaultConfig,
            trackingConsent: .mockRandom()
        )

        Flashcat.initialize(
            with: defaultConfig,
            trackingConsent: .mockRandom()
        )

        XCTAssertEqual(
            printFunction.printedMessage,
            "🔥 Datadog SDK usage error: The 'main' instance of SDK is already initialized."
        )

        Flashcat.flushAndDeinitialize()
    }

    // MARK: - Public APIs

    func testTrackingConsent() {
        let initialConsent: TrackingConsent = .mockRandom()
        let nextConsent: TrackingConsent = .mockRandom()

        Flashcat.initialize(
            with: defaultConfig,
            trackingConsent: initialConsent
        )

        let core = CoreRegistry.default as? FlashcatCore
        XCTAssertEqual(core?.consentPublisher.consent, initialConsent)

        Flashcat.set(trackingConsent: nextConsent)

        XCTAssertEqual(core?.consentPublisher.consent, nextConsent)

        Flashcat.flushAndDeinitialize()
    }

    func testUserInfo() {
        Flashcat.initialize(
            with: defaultConfig,
            trackingConsent: .mockRandom()
        )

        let core = CoreRegistry.default as? FlashcatCore

        XCTAssertNil(core?.userInfoPublisher.current.id)
        XCTAssertNil(core?.userInfoPublisher.current.email)
        XCTAssertNil(core?.userInfoPublisher.current.name)
        XCTAssertEqual(core?.userInfoPublisher.current.extraInfo as? [String: Int], [:])

        Flashcat.setUserInfo(
            id: "foo",
            name: "bar",
            email: "foo@bar.com",
            extraInfo: ["abc": 123]
        )
        core?.set(anonymousId: "anonymous-id")

        XCTAssertEqual(core?.userInfoPublisher.current.anonymousId, "anonymous-id")
        XCTAssertEqual(core?.userInfoPublisher.current.id, "foo")
        XCTAssertEqual(core?.userInfoPublisher.current.name, "bar")
        XCTAssertEqual(core?.userInfoPublisher.current.email, "foo@bar.com")
        XCTAssertEqual(core?.userInfoPublisher.current.extraInfo as? [String: Int], ["abc": 123])

        Flashcat.clearUserInfo()

        XCTAssertEqual(core?.userInfoPublisher.current.anonymousId, "anonymous-id")
        XCTAssertNil(core?.userInfoPublisher.current.id)
        XCTAssertNil(core?.userInfoPublisher.current.email)
        XCTAssertNil(core?.userInfoPublisher.current.name)
        XCTAssertEqual(core?.userInfoPublisher.current.extraInfo as? [String: Int], [:])

        Flashcat.flushAndDeinitialize()
    }

    func testAddUserProperties_mergesProperties() {
        Flashcat.initialize(
            with: defaultConfig,
            trackingConsent: .mockRandom()
        )

        let core = CoreRegistry.default as? FlashcatCore

        Flashcat.setUserInfo(
            id: "foo",
            name: "bar",
            email: "foo@bar.com",
            extraInfo: ["abc": 123]
        )

        Flashcat.addUserExtraInfo(["second": 667])

        XCTAssertEqual(core?.userInfoPublisher.current.id, "foo")
        XCTAssertEqual(core?.userInfoPublisher.current.name, "bar")
        XCTAssertEqual(core?.userInfoPublisher.current.email, "foo@bar.com")
        XCTAssertEqual(
            core?.userInfoPublisher.current.extraInfo as? [String: Int],
            ["abc": 123, "second": 667]
        )

        Flashcat.flushAndDeinitialize()
    }

    func testAddUserProperties_removesProperties() {
        Flashcat.initialize(
            with: defaultConfig,
            trackingConsent: .mockRandom()
        )

        let core = CoreRegistry.default as? FlashcatCore

        Flashcat.setUserInfo(
            id: "foo",
            name: "bar",
            email: "foo@bar.com",
            extraInfo: ["abc": 123]
        )

        Flashcat.addUserExtraInfo(["abc": nil, "second": 667])

        XCTAssertEqual(core?.userInfoPublisher.current.id, "foo")
        XCTAssertEqual(core?.userInfoPublisher.current.name, "bar")
        XCTAssertEqual(core?.userInfoPublisher.current.email, "foo@bar.com")
        XCTAssertEqual(core?.userInfoPublisher.current.extraInfo as? [String: Int], ["second": 667])

        Flashcat.flushAndDeinitialize()
    }

    func testAddUserProperties_overwritesProperties() {
        Flashcat.initialize(
            with: defaultConfig,
            trackingConsent: .mockRandom()
        )

        let core = CoreRegistry.default as? FlashcatCore

        Flashcat.setUserInfo(
            id: "foo",
            name: "bar",
            email: "foo@bar.com",
            extraInfo: ["abc": 123]
        )

        Flashcat.addUserExtraInfo(["abc": 444])

        XCTAssertEqual(core?.userInfoPublisher.current.id, "foo")
        XCTAssertEqual(core?.userInfoPublisher.current.name, "bar")
        XCTAssertEqual(core?.userInfoPublisher.current.email, "foo@bar.com")
        XCTAssertEqual(core?.userInfoPublisher.current.extraInfo as? [String: Int], ["abc": 444])

        Flashcat.flushAndDeinitialize()
    }

    func testAccountInfo() {
        Flashcat.initialize(
            with: defaultConfig,
            trackingConsent: .mockRandom()
        )

        let core = CoreRegistry.default as? FlashcatCore

        XCTAssertNil(core?.accountInfoPublisher.current)

        Flashcat.setAccountInfo(
            id: "foo",
            name: "bar",
            extraInfo: ["abc": 123]
        )

        XCTAssertEqual(core?.accountInfoPublisher.current?.id, "foo")
        XCTAssertEqual(core?.accountInfoPublisher.current?.name, "bar")
        XCTAssertEqual(core?.accountInfoPublisher.current?.extraInfo as? [String: Int], ["abc": 123])

        Flashcat.flushAndDeinitialize()
    }

    func testAddAccountProperties_mergesProperties() {
        Flashcat.initialize(
            with: defaultConfig,
            trackingConsent: .mockRandom()
        )

        let core = CoreRegistry.default as? FlashcatCore

        Flashcat.setAccountInfo(
            id: "foo",
            name: "bar",
            extraInfo: ["abc": 123]
        )

        Flashcat.addAccountExtraInfo(["second": 667])

        XCTAssertEqual(core?.accountInfoPublisher.current?.id, "foo")
        XCTAssertEqual(core?.accountInfoPublisher.current?.name, "bar")
        XCTAssertEqual(
            core?.accountInfoPublisher.current?.extraInfo as? [String: Int],
            ["abc": 123, "second": 667]
        )

        Flashcat.flushAndDeinitialize()
    }

    func testAddAccountProperties_removesProperties() {
        Flashcat.initialize(
            with: defaultConfig,
            trackingConsent: .mockRandom()
        )

        let core = CoreRegistry.default as? FlashcatCore

        Flashcat.setAccountInfo(
            id: "foo",
            name: "bar",
            extraInfo: ["abc": 123]
        )

        Flashcat.addAccountExtraInfo(["abc": nil, "second": 667])

        XCTAssertEqual(core?.accountInfoPublisher.current?.id, "foo")
        XCTAssertEqual(core?.accountInfoPublisher.current?.name, "bar")
        XCTAssertEqual(core?.accountInfoPublisher.current?.extraInfo as? [String: Int], ["second": 667])

        Flashcat.flushAndDeinitialize()
    }

    func testAddAccountProperties_overwritesProperties() {
        Flashcat.initialize(
            with: defaultConfig,
            trackingConsent: .mockRandom()
        )

        let core = CoreRegistry.default as? FlashcatCore

        Flashcat.setAccountInfo(
            id: "foo",
            name: "bar",
            extraInfo: ["abc": 123]
        )

        Flashcat.addAccountExtraInfo(["abc": 444])

        XCTAssertEqual(core?.accountInfoPublisher.current?.id, "foo")
        XCTAssertEqual(core?.accountInfoPublisher.current?.name, "bar")
        XCTAssertEqual(core?.accountInfoPublisher.current?.extraInfo as? [String: Int], ["abc": 444])

        Flashcat.flushAndDeinitialize()
    }

    func testDefaultVerbosityLevel() {
        XCTAssertNil(Flashcat.verbosityLevel)
    }

    func testGivenDataStoredInAllFeatureDirectories_whenClearAllDataIsUsed_allFilesAreRemoved() throws {
        Flashcat.initialize(
            with: defaultConfig,
            trackingConsent: .mockRandom()
        )

        Logs.enable()
        Trace.enable()

        let core = try XCTUnwrap(CoreRegistry.default as? FlashcatCore)

        // On SDK init, underlying `ConsentAwareDataWriter` performs data migration for each feature, which includes
        // data removal in `unauthorised` (`.pending`) directory. To not cause test flakiness, we must ensure that
        // mock data is written only after this operation completes - otherwise, migration may delete mocked files.
        core.readWriteQueue.sync {}

        // Given
        let featureDirectories: [FeatureDirectories] = [
            try core.directory.getFeatureDirectories(forFeatureNamed: "logging"),
            try core.directory.getFeatureDirectories(forFeatureNamed: "tracing"),
        ]

        let scope = core.scope(for: TraceFeature.self)
        scope.dataStore.setValue("foo".data(using: .utf8)!, forKey: "bar")

        // Wait for async clear completion in all features:
        core.readWriteQueue.sync {}
        let tracingDataStoreDir = try core.directory.coreDirectory.subdirectory(path: core.directory.getDataStorePath(forFeatureNamed: "tracing"))
        XCTAssertTrue(tracingDataStoreDir.hasFile(named: "bar"))

        var allDirectories: [Directory] = featureDirectories.flatMap { [$0.authorized, $0.unauthorized] }
        allDirectories.append(.init(url: tracingDataStoreDir.url))
        try allDirectories.forEach { directory in _ = try directory.createFile(named: .mockRandom()) }

        // When
        Flashcat.clearAllData()

        // Wait for async clear completion in all features:
        core.readWriteQueue.sync {}

        // Then
        let files: [File] = allDirectories.reduce([], { acc, nextDirectory in
            let next = try? nextDirectory.files()
            return acc + (next ?? [])
        })
        XCTAssertEqual(files, [], "All files must be removed")

        Flashcat.flushAndDeinitialize()
    }

    func testServerDateProvider() throws {
        // Given
        var config = defaultConfig
        let serverDateProvider = ServerDateProviderMock()
        config.serverDateProvider = serverDateProvider

        // When
        Flashcat.initialize(
            with: config,
            trackingConsent: .mockRandom()
        )

        serverDateProvider.offset = -1

        // Then
        let core = try XCTUnwrap(CoreRegistry.default as? FlashcatCore)
        let context = core.contextProvider.read()
        XCTAssertEqual(context.serverTimeOffset, -1)

        Flashcat.flushAndDeinitialize()
    }

    func testRemoveV1DeprecatedFolders() throws {
        // Given
        let cache = try Directory.cache()
        let directories = ["com.datadoghq.logs", "com.datadoghq.traces", "com.datadoghq.rum"]
        try directories.forEach {
            _ = try cache.createSubdirectory(path: $0).createFile(named: "test")
        }

        // When
        Flashcat.initialize(
            with: defaultConfig,
            trackingConsent: .mockRandom()
        )

        defer { Flashcat.flushAndDeinitialize() }

        let core = try XCTUnwrap(CoreRegistry.default as? FlashcatCore)
        // Wait for async deletion
        core.readWriteQueue.sync {}

        // Then
        XCTAssertThrowsError(try cache.subdirectory(path: "com.datadoghq.logs"))
        XCTAssertThrowsError(try cache.subdirectory(path: "com.datadoghq.traces"))
        XCTAssertThrowsError(try cache.subdirectory(path: "com.datadoghq.rum"))
    }

    func testCustomSDKInstance() throws {
        // When
        Flashcat.initialize(
            with: defaultConfig,
            trackingConsent: .mockRandom(),
            instanceName: "test"
        )

        defer { Flashcat.flushAndDeinitialize(instanceName: "test") }

        // Then
        XCTAssertTrue(CoreRegistry.default is NOPDatadogCore)
        XCTAssertTrue(CoreRegistry.instance(named: "test") is FlashcatCore)
    }

    func testStopSDKInstance() throws {
        // Given
        Flashcat.initialize(
            with: defaultConfig,
            trackingConsent: .mockRandom(),
            instanceName: "test"
        )

        // Then
        XCTAssertTrue(CoreRegistry.instance(named: "test") is FlashcatCore)

        // When
        Flashcat.stopInstance(named: "test")

        // Then
        XCTAssertTrue(CoreRegistry.instance(named: "test") is NOPDatadogCore)
    }

    func testGivenDefaultSDKInstanceInitialized_customOneCanBeInitializedAfterIt() throws {
        let defaultConfig = Flashcat.Configuration(clientToken: "abc-123", env: "default")
        let customConfig = Flashcat.Configuration(clientToken: "def-456", env: "custom")

        // Given
        Flashcat.initialize(
            with: defaultConfig,
            trackingConsent: .mockRandom()
        )
        defer { Flashcat.flushAndDeinitialize() }

        // When
        Flashcat.initialize(
            with: customConfig,
            trackingConsent: .mockRandom(),
            instanceName: "custom-instance"
        )
        defer { Flashcat.flushAndDeinitialize(instanceName: "custom-instance") }

        // Then
        XCTAssertTrue(CoreRegistry.default is FlashcatCore)
        XCTAssertTrue(CoreRegistry.instance(named: "custom-instance") is FlashcatCore)
    }
}
