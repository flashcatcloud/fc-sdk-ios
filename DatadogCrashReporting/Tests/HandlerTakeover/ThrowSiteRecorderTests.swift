/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import XCTest
@testable import DatadogCrashReporting

class ThrowSiteRecorderTests: XCTestCase {
    func testThrowSiteIsTheFirstFrameBelowTheRuntimeAndAnyInterposedThrow() {
        let frames: [[String: Any]] = [
            ["object_name": "App", "symbol_name": "terminateHandler"],
            ["object_name": "libc++abi.dylib", "symbol_name": "std::__terminate"],
            ["object_name": "libc++abi.dylib", "symbol_name": "failed_throw"],
            ["object_name": "libc++abi.dylib", "symbol_name": "__cxa_throw"],
            ["object_name": "App", "symbol_name": "__cxa_throw"], // defined by another library linked into the app
            ["object_name": "App", "symbol_name": "parseMessage"],
            ["object_name": "App", "symbol_name": "main"],
        ]
        XCTAssertEqual(ThrowSiteRecorder.throwSiteIndex(in: frames), 5)
    }

    func testThrowSiteIsTheFirstFrameWhenThereIsNoRuntimeFrame() {
        let frames: [[String: Any]] = [["object_name": "App", "symbol_name": "a"], ["object_name": "App", "symbol_name": "b"]]
        XCTAssertEqual(ThrowSiteRecorder.throwSiteIndex(in: frames), 0)
    }

    func testRecordedThrowSiteCanBeRead() throws {
        // Given
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("throw-site-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        ThrowSiteRecorder.prepare(file: file)

        // When
        ThrowSiteRecorder.record()

        // Then
        let throwSite = try XCTUnwrap(ThrowSiteRecorder.read(from: file))
        XCTAssertEqual(throwSite.processID, Int64(getpid()))
        XCTAssertLessThan(abs(throwSite.date.timeIntervalSinceNow), 10)
        let frame = try XCTUnwrap(throwSite.frames.first)
        XCTAssertNotNil(frame["instruction_addr"])
        XCTAssertNotNil(frame["object_addr"])
        XCTAssertNotNil(frame["object_name"])
    }

    func testReadingAMissingOrInvalidFileGivesNothing() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("throw-site-\(UUID().uuidString).json")
        XCTAssertNil(ThrowSiteRecorder.read(from: file))
        try Data("not json".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertNil(ThrowSiteRecorder.read(from: file))
    }
}
