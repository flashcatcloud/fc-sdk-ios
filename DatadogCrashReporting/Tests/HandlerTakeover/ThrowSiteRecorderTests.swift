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
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("throw-site-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        ThrowSiteRecorder.prepare(file: file)

        // When
        ThrowSiteRecorder.record()

        // Then
        let throwSite = try XCTUnwrap(ThrowSiteRecorder.read(from: file))
        XCTAssertEqual(throwSite.processID, Int64(getpid()))
        XCTAssertLessThan(abs(throwSite.date.timeIntervalSinceNow), 10)
        XCTAssertGreaterThan(throwSite.addresses.count, 1)
        var info = Dl_info()
        let recordFrame = try XCTUnwrap(UnsafeRawPointer(bitPattern: UInt(throwSite.addresses[0])))
        XCTAssertNotEqual(dladdr(recordFrame, &info), 0, "Raw return addresses of this process are recorded")
    }

    func testPreparingKeepsThePreviousRecordUntilANewOneIsWritten() throws {
        // Given
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("throw-site-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        ThrowSiteRecorder.prepare(file: file)
        ThrowSiteRecorder.record()
        let previous = try XCTUnwrap(ThrowSiteRecorder.read(from: file))

        // When (the next launch)
        ThrowSiteRecorder.prepare(file: file)

        // Then
        XCTAssertEqual(ThrowSiteRecorder.read(from: file)?.addresses, previous.addresses)
    }

    func testItDoesNotRecordObjectiveCExceptions() {
        func typeInfo(named name: String) -> Bool {
            name.withCString { name in
                var typeInfo: (UnsafeRawPointer?, UnsafePointer<CChar>?) = (nil, name)
                return withUnsafeBytes(of: &typeInfo) { ThrowSiteRecorder.shouldRecord(exceptionType: $0.baseAddress!) }
            }
        }
        XCTAssertFalse(typeInfo(named: "NSException"))
        XCTAssertTrue(typeInfo(named: "St13runtime_error"))
    }

    func testReadingAMissingOrInvalidFileGivesNothing() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("throw-site-\(UUID().uuidString)")
        XCTAssertNil(ThrowSiteRecorder.read(from: file))
        try Data(repeating: 0xAB, count: ThrowSiteRecorder.recordSize).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertNil(ThrowSiteRecorder.read(from: file))
    }
}
