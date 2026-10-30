/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import XCTest
@testable import DatadogCrashReporting

// swiftlint:disable duplicate_imports
#if COCOAPODS
import KSCrash
#elseif swift(>=6.0)
internal import KSCrashRecording
internal import KSCrashFilters
#else
@_implementationOnly import KSCrashRecording
@_implementationOnly import KSCrashFilters
#endif
// swiftlint:enable duplicate_imports

class DatadogCppThrowSiteFilterTests: XCTestCase {
    private let crashDate = Date(timeIntervalSince1970: 1_761_000_000)
    /// The app image at crash time; at the next launch it is loaded at another address.
    private let appImage: UInt64 = 0x1_0000_0000
    private let libcxxabiImage: UInt64 = 0x4_0000_0000
    /// Return addresses at crash time, innermost first: the terminate machinery, then the throw site and its caller.
    private var throwSiteAddresses: [UInt64] { [libcxxabiImage + 0x100, libcxxabiImage + 0x200, appImage + 0x1100, appImage + 0x2200] }

    private func report(
        type: String = "cpp_exception",
        processID: Int64 = 42,
        crashedStack: [[String: Any]] = [],
        appUUID: String = "00000000-0000-0000-0000-00000000000A"
    ) -> CrashFieldDictionary {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return CrashFieldDictionary(from: jsonRoundTrip([
            "report": ["timestamp": formatter.string(from: crashDate), "id": "report-1"],
            "system": ["process_id": processID, "cpu_arch": "arm64"],
            "crash": [
                "error": ["type": type],
                "threads": [
                    ["index": 0, "crashed": true, "backtrace": ["contents": crashedStack, "skipped": 0]],
                    ["index": 1, "crashed": false, "backtrace": ["contents": [["instruction_addr": 0x2_0000_0100, "object_addr": 0x2_0000_0000]], "skipped": 0]],
                ]
            ],
            "binary_images": [
                ["image_addr": appImage, "image_size": 0x10_0000, "name": "/App/App", "uuid": appUUID],
                ["image_addr": 0x2_0000_0000, "image_size": 0x10_0000, "name": "/usr/lib/libsystem_kernel.dylib"],
                ["image_addr": 0x3_0000_0000, "image_size": 0x10_0000, "name": "/usr/lib/unused.dylib"],
                ["image_addr": libcxxabiImage, "image_size": 0x10_0000, "name": "/usr/lib/libc++abi.dylib"],
            ]
        ]))
    }

    /// Values as KSCrash reports carry them (`NSNumber`), not Swift literals.
    private func jsonRoundTrip(_ dict: [String: Any]) -> [String: Any] {
        // swiftlint:disable:next force_try force_cast
        try! JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: dict)) as! [String: Any]
    }

    private func throwSite(processID: Int64 = 42, secondsAfterCrash: TimeInterval = 0) -> ThrowSiteRecorder.ThrowSite {
        .init(processID: processID, date: crashDate.addingTimeInterval(secondsAfterCrash), addresses: throwSiteAddresses)
    }

    private func crashedStack(_ report: CrashFieldDictionary) throws -> [CrashFieldDictionary] {
        let threads: [CrashFieldDictionary] = try report.value(forKey: .crash, .threads)
        return try threads[0].value(forKey: .backtrace, .contents)
    }

    private let filter = DatadogCppThrowSiteFilter(throwSiteFile: URL(fileURLWithPath: "/dev/null"))

    func testItFillsTheEmptyStackOfACppExceptionWithTheThrowSiteOfTheSameProcess() throws {
        let filled = try XCTUnwrap(filter.fill(report: report(), with: throwSite(), loadedImages: [:]))
        let stack = try crashedStack(filled)
        XCTAssertEqual(stack.count, 2, "The C++ runtime frames above the throw site are dropped")
        XCTAssertEqual(try stack[0].value(Int64.self, forKey: .instructionAddr), Int64(appImage + 0x1100))
        XCTAssertEqual(try stack[0].value(Int64.self, forKey: .objectAddr), Int64(appImage))
        XCTAssertEqual(try stack[0].value(String.self, forKey: .objectName), "App")
    }

    func testItSymbolicatesTheThrowSiteThroughTheSameImageLoadedInTheCurrentProcess() throws {
        // Given (`getpid`, loaded in this process, stands for a function of the crashed process's image)
        let function = try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "getpid"))
        var info = Dl_info()
        XCTAssertNotEqual(dladdr(function, &info), 0)
        let base = UInt(bitPattern: try XCTUnwrap(info.dli_fbase))
        let loadedImages = ThrowSiteRecorder.loadedImages()
        let uuid = try XCTUnwrap(loadedImages.first { $0.value == base }?.key)
        let offset = UInt64(UInt(bitPattern: function) - base)
        let symbolName = String(cString: try XCTUnwrap(info.dli_sname))
        let symbolOffset = UInt64(UInt(bitPattern: try XCTUnwrap(info.dli_saddr)) - base)

        // When
        let frame = try DatadogCppThrowSiteFilter.frame(
            at: appImage + offset + 4, // a return address inside the function
            images: [CrashFieldDictionary(from: jsonRoundTrip(["image_addr": appImage, "image_size": 0x1000_0000, "name": "/usr/lib/x.dylib", "uuid": uuid]))],
            loadedImages: loadedImages
        )

        // Then
        XCTAssertEqual(frame["symbol_name"] as? String, symbolName)
        XCTAssertEqual(frame["symbol_addr"] as? Int64, Int64(appImage + symbolOffset), "In the crashed process's address space")
        XCTAssertEqual(frame["object_name"] as? String, "x.dylib")
    }

    func testAnAddressOutsideOfEveryImageKeepsOnlyItsAddress() throws {
        let frame = try DatadogCppThrowSiteFilter.frame(at: 0x9_0000_0000, images: [], loadedImages: [:])
        XCTAssertEqual(frame.count, 1)
        XCTAssertEqual(frame["instruction_addr"] as? Int64, 0x9_0000_0000)
    }

    func testItLeavesOtherReportsUnchanged() throws {
        XCTAssertNil(try filter.fill(report: report(type: "signal"), with: throwSite(), loadedImages: [:]), "not a C++ exception")
        XCTAssertNil(try filter.fill(report: report(processID: 7), with: throwSite(), loadedImages: [:]), "another process")
        XCTAssertNil(try filter.fill(report: report(), with: throwSite(secondsAfterCrash: 3_600), loadedImages: [:]), "another crash of a process with the same ID")
        XCTAssertNil(
            try filter.fill(report: report(crashedStack: [["instruction_addr": 0x1_0000_9000, "object_addr": 0x1_0000_0000]]), with: throwSite(), loadedImages: [:]),
            "the crash reporter has a stack of its own"
        )
    }

    func testInThePipeline_theThrowSiteImagesAreKeptByMinify() throws {
        // Given
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("throw-site-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try record(throwSite()).write(to: file)

        // When
        var output: [CrashReport]?
        CrashReportFilterPipeline(filters: [DatadogCppThrowSiteFilter(throwSiteFile: file), DatadogMinifyFilter()])
            .filterReports([AnyCrashReport(report())]) { reports, error in
                XCTAssertNil(error)
                output = reports
            }

        // Then
        let result = try XCTUnwrap(output?.first?.untypedValue as? CrashFieldDictionary)
        XCTAssertEqual(try crashedStack(result).count, 2)
        let images: [CrashFieldDictionary] = try result.value(forKey: .binaryImages)
        XCTAssertEqual(try images.map { try $0.value(Int64.self, forKey: .imageAddress) }.sorted(), [0x1_0000_0000, 0x2_0000_0000])
    }

    /// A record in the layout `ThrowSiteRecorder.record()` writes.
    private func record(_ throwSite: ThrowSiteRecorder.ThrowSite) -> Data {
        var data = Data(count: ThrowSiteRecorder.recordSize)
        data.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of: ThrowSiteRecorder.magic, as: UInt32.self)
            bytes.storeBytes(of: UInt32(throwSite.addresses.count), toByteOffset: 4, as: UInt32.self)
            bytes.storeBytes(of: throwSite.processID, toByteOffset: 8, as: Int64.self)
            bytes.storeBytes(of: Int64(throwSite.date.timeIntervalSince1970 * 1_000_000), toByteOffset: 16, as: Int64.self)
            for (index, address) in throwSite.addresses.enumerated() {
                bytes.storeBytes(of: address, toByteOffset: ThrowSiteRecorder.headerSize + index * 8, as: UInt64.self)
            }
        }
        return data
    }
}
