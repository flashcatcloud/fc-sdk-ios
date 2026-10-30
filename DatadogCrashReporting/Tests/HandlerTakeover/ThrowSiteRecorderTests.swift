/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import XCTest
import MachO
@testable import DatadogCrashReporting

private var backtraceCalls = 0

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

    func testRecordingDoesNotUnwindWithBacktrace() throws {
        // Given (`backtrace()` takes locks and may be bound lazily: not callable while terminating)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("throw-site-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let index = try XCTUnwrap((0..<_dyld_image_count()).first {
            String(cString: _dyld_get_image_name($0)).hasSuffix("/DatadogCrashReporting.framework/DatadogCrashReporting")
        })
        let header = try XCTUnwrap(_dyld_get_image_header(index))
        let countingBacktrace: @convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>?, Int32) -> Int32 = { _, _ in
            backtraceCalls += 1
            return 0
        }
        let realBacktrace = try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "backtrace"))
        SymbolRebinder.rebind([.init(name: "_backtrace", replacement: unsafeBitCast(countingBacktrace, to: UnsafeRawPointer.self))], inImage: header, slide: _dyld_get_image_vmaddr_slide(index))
        defer {
            SymbolRebinder.rebind([.init(name: "_backtrace", replacement: UnsafeRawPointer(realBacktrace))], inImage: header, slide: _dyld_get_image_vmaddr_slide(index))
        }
        ThrowSiteRecorder.prepare(file: file)
        backtraceCalls = 0

        // When
        ThrowSiteRecorder.record()

        // Then
        XCTAssertEqual(backtraceCalls, 0)
        XCTAssertGreaterThan(try XCTUnwrap(ThrowSiteRecorder.read(from: file)).addresses.count, 1)
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
