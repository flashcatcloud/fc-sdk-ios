/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import XCTest
import DatadogInternal
import TestUtilities
@testable import DatadogRUM

class FatalErrorContextNotifierTests: XCTestCase {
    private let featureScope = FeatureScopeMock()

    private var sharedContext: RUMFatalErrorContext? {
        featureScope.contextMock.additionalContext(ofType: RUMFatalErrorContext.self)
    }

    // MARK: - Changing Session State

    func testWhenSessionStateIsSet_itSharesItInCoreContext() throws {
        // Given
        let fatalErrorContext = FatalErrorContextNotifier(featureScope: featureScope)
        let newSessionState: RUMSessionState = .mockRandom()

        // When
        fatalErrorContext.sessionState = newSessionState

        // Then
        XCTAssertEqual(try XCTUnwrap(sharedContext).sessionState, newSessionState)
        XCTAssertEqual(fatalErrorContext.sessionState, newSessionState)
    }

    func testWhenTheSessionStateDoesNotChange_itRequestsNoWrite() {
        // Given
        let fatalErrorContext = FatalErrorContextNotifier(featureScope: featureScope)
        let sessionState: RUMSessionState = .mockRandom()
        fatalErrorContext.sessionState = sessionState
        let requests = featureScope.contextWriteRequests

        // When
        fatalErrorContext.sessionState = sessionState
        fatalErrorContext.view = nil // there was no view

        // Then
        XCTAssertEqual(featureScope.contextWriteRequests, requests)
    }

    func testChangesMadeBeforeAPendingWriteRunsAreWrittenByIt() throws {
        // Given
        featureScope.defersContextWrites = true
        let fatalErrorContext = FatalErrorContextNotifier(featureScope: featureScope)
        let sessionState: RUMSessionState = .mockRandom()
        let view: RUMViewEvent = .mockRandom()

        // When
        fatalErrorContext.sessionState = sessionState
        fatalErrorContext.view = view
        fatalErrorContext.globalAttributes = ["key": "value"]
        featureScope.runPendingContextWrites()

        // Then
        XCTAssertEqual(featureScope.contextWriteRequests, 1, "Changes are coalesced into the pending write")
        let shared = try XCTUnwrap(sharedContext)
        XCTAssertEqual(shared.sessionState, sessionState)
        DDAssertJSONEqual(try XCTUnwrap(shared.view), view)

        // When (a change after the write ran)
        fatalErrorContext.view = nil
        featureScope.runPendingContextWrites()

        // Then
        XCTAssertEqual(featureScope.contextWriteRequests, 2)
        XCTAssertNil(sharedContext?.view)
    }

    // MARK: - Changing View State

    func testWhenViewIsSet_itSharesItInCoreContext() throws {
        // Given
        let fatalErrorContext = FatalErrorContextNotifier(featureScope: featureScope)
        let newViewEvent: RUMViewEvent = .mockRandom()

        // When
        fatalErrorContext.view = newViewEvent

        // Then
        DDAssertJSONEqual(try XCTUnwrap(sharedContext?.view), newViewEvent)
    }

    func testWhenViewIsReset_itSharesNoView() throws {
        // Given
        let fatalErrorContext = FatalErrorContextNotifier(featureScope: featureScope)
        let sessionState: RUMSessionState = .mockRandom()
        fatalErrorContext.sessionState = sessionState
        fatalErrorContext.view = .mockRandom()

        // When
        fatalErrorContext.view = nil

        // Then
        let shared = try XCTUnwrap(sharedContext)
        XCTAssertNil(shared.view)
        XCTAssertEqual(shared.sessionState, sessionState, "Other values must be kept")
    }

    // MARK: - Changing Global Attributes

    func testWhenGlobalAttributesAreSet_itSharesThemInCoreContext() throws {
        // Given
        let fatalErrorContext = FatalErrorContextNotifier(featureScope: featureScope)
        let newGlobalAttributes = mockRandomAttributes()

        // When
        fatalErrorContext.globalAttributes = newGlobalAttributes

        // Then
        DDAssertJSONEqual(try XCTUnwrap(sharedContext?.globalAttributes), RUMEventAttributes(contextInfo: newGlobalAttributes))
    }

    func testUntilGlobalAttributesAreSet_itSharesNoAttributes() throws {
        // When
        let fatalErrorContext = FatalErrorContextNotifier(featureScope: featureScope)
        fatalErrorContext.view = .mockRandom()

        // Then (no attributes, rather than empty ones, so the attributes of the last view are kept)
        XCTAssertNil(try XCTUnwrap(sharedContext).globalAttributes)
    }

    // MARK: - Identity

    func testEveryChangeSharesANewInstance() throws {
        // Given
        let fatalErrorContext = FatalErrorContextNotifier(featureScope: featureScope)
        fatalErrorContext.sessionState = .mockRandom()
        let first = try XCTUnwrap(sharedContext)

        // When
        fatalErrorContext.view = .mockRandom()

        // Then
        let second = try XCTUnwrap(sharedContext)
        XCTAssertFalse(first === second, "Crash Reporting detects changes by identity")
        XCTAssertEqual(first.sessionState, second.sessionState)
    }
}
