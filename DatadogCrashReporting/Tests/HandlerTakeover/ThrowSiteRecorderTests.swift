/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import XCTest
import MachO
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

    func testStrippingPointerAuthenticationKeepsTheAddressBitsAboveThe36th() {
        let address: UInt = 0x0000_1234_5678_9ABC // above 2^36, below the 47-bit user space limit
        let signed: UInt = 0x8A2D_0000_0000_0000 | address
        XCTAssertEqual(signed & ThrowSiteRecorder.arm64ReturnAddressMask, address)
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

    @inline(never)
    private func recordFromANamedFrame() {
        ThrowSiteRecorder.record()
    }

    func testRecordedThrowSiteIsTheStackOfTheCaller() throws {
        // Given
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("throw-site-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        ThrowSiteRecorder.prepare(file: file)

        // When
        recordFromANamedFrame()

        // Then
        let throwSite = try XCTUnwrap(ThrowSiteRecorder.read(from: file))
        XCTAssertLessThanOrEqual(throwSite.addresses.count, ThrowSiteRecorder.maxFrames)
        let symbols = throwSite.addresses.prefix(4).map { address -> String in
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: UInt(address)), &info) != 0, let name = info.dli_sname else {
                return "?"
            }
            return String(cString: name)
        }
        XCTAssertTrue(symbols.contains { $0.contains("recordFromANamedFrame") }, "\(symbols)")
    }

    func testTheTerminateHandlerRecordsTheThrowSiteOfAnUncaughtCppException_thenCallsTheHandlerItReplaced() throws {
        try XCTSkipIf(throwRuntimeError == nil)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("throw-site-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try withParkingTerminate {
            // Given
            XCTAssertTrue(ThrowSiteRecorder.installTerminateHandler(file: file))

            // When
            startUncaughtThrow(objectiveC: false)

            // Then
            XCTAssertEqual(parkedSemaphore.wait(timeout: .now() + 5), .success, "the replaced handler is called")
            let throwSite = try XCTUnwrap(ThrowSiteRecorder.read(from: file))
            XCTAssertEqual(throwSite.processID, Int64(getpid()))
            let frames = throwSite.addresses.map(localFrame)
            let index = ThrowSiteRecorder.throwSiteIndex(in: frames)
            let names = frames.map { ($0["object_name"] as? String ?? "?") + ":" + ($0["symbol_name"] as? String ?? "?") }
            XCTAssertGreaterThan(index, 0, "\(names)")
            XCTAssertTrue(names.indices.contains(index) && names[index].contains("throwFromNamedSite"), "\(names)")
        }
    }

    func testTheTerminateHandlerDoesNotRecordObjectiveCExceptions_butCallsTheHandlerItReplaced() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("throw-site-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try withParkingTerminate {
            XCTAssertTrue(ThrowSiteRecorder.installTerminateHandler(file: file))

            startUncaughtThrow(objectiveC: true)

            XCTAssertEqual(parkedSemaphore.wait(timeout: .now() + 5), .success, "the replaced handler is called")
            XCTAssertNil(ThrowSiteRecorder.read(from: file))
        }
    }

    func testUninstallingPutsBackTheHandlerItReplaced() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("throw-site-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let before = getTerminate()

        XCTAssertTrue(ThrowSiteRecorder.installTerminateHandler(file: file))
        XCTAssertNotEqual(getTerminate(), before)
        XCTAssertTrue(ThrowSiteRecorder.installTerminateHandler(file: file), "installing again keeps the installed handler")
        ThrowSiteRecorder.uninstallTerminateHandler()

        XCTAssertEqual(getTerminate(), before)
    }

    // MARK: - Uncaught exceptions

    /// Replaces the terminate handler with one that parks the terminating thread (instead of aborting the test process),
    /// as the crash reporter's handler the recorder replaces.
    private func withParkingTerminate(_ body: () throws -> Void) rethrows {
        let previous = setTerminate(unsafeBitCast(parkingTerminate, to: UnsafeMutableRawPointer.self))
        defer {
            ThrowSiteRecorder.uninstallTerminateHandler()
            _ = setTerminate(previous)
        }
        try body()
    }

    /// A frame with the keys `ThrowSiteRecorder.throwSiteIndex(in:)` reads, for an address of this process.
    private func localFrame(_ address: UInt64) -> [String: Any] {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: UInt(address) - 1), &info) != 0 else {
            return [:]
        }
        var frame: [String: Any] = [:]
        if let path = info.dli_fname {
            frame["object_name"] = (String(cString: path) as NSString).lastPathComponent
        }
        if let name = info.dli_sname {
            frame["symbol_name"] = String(cString: name)
        }
        return frame
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

private typealias SetTerminate = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
private typealias GetTerminate = @convention(c) () -> UnsafeMutableRawPointer?
private typealias ThrowRuntimeError = @convention(c) (UnsafePointer<CChar>?) -> Void

private let setTerminate = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_ZSt13set_terminatePFvvE"), to: SetTerminate.self)
private let getTerminate = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_ZSt13get_terminatev"), to: GetTerminate.self)
/// `std::__throw_runtime_error(const char *)` of libc++: throws a C++ exception from the C++ runtime.
private let throwRuntimeError = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_ZNSt3__121__throw_runtime_errorEPKc")
    .map { unsafeBitCast($0, to: ThrowRuntimeError.self) }

private let parkedSemaphore = DispatchSemaphore(value: 0)
/// Never returns: the thread that terminated is parked instead of aborting the test process.
private let parkingTerminate: @convention(c) () -> Void = {
    parkedSemaphore.signal()
    while true { sleep(1_000) }
}

@inline(never)
private func throwFromNamedSite() { throwRuntimeError?("uncaught") }
@inline(never)
private func raiseFromNamedSite() { NSException(name: .genericException, reason: "uncaught", userInfo: nil).raise() }

/// Throws on a new thread that never catches.
private func startUncaughtThrow(objectiveC: Bool) {
    var thread: pthread_t?
    let entry: @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? = { argument in
        if argument == UnsafeMutableRawPointer(bitPattern: 1) {
            raiseFromNamedSite()
        } else {
            throwFromNamedSite()
        }
        return nil
    }
    pthread_create(&thread, nil, entry, UnsafeMutableRawPointer(bitPattern: objectiveC ? 1 : 2)!)
}
