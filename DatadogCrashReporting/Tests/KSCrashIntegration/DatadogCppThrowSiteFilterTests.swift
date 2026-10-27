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
    private let throwSiteFrames: [[String: Any]] = [
        ["instruction_addr": 0x1_0000_1100, "object_addr": 0x1_0000_0000, "object_name": "App", "symbol_addr": 0x1_0000_1000, "symbol_name": "parseMessage"],
        ["instruction_addr": 0x1_0000_2200, "object_addr": 0x1_0000_0000, "object_name": "App", "symbol_addr": 0x1_0000_2000, "symbol_name": "main"],
    ]

    private func report(type: String = "cpp_exception", processID: Int64 = 42, crashedStack: [[String: Any]] = []) -> CrashFieldDictionary {
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
                ["image_addr": 0x1_0000_0000, "name": "/App/App"],
                ["image_addr": 0x2_0000_0000, "name": "/usr/lib/libsystem_kernel.dylib"],
                ["image_addr": 0x3_0000_0000, "name": "/usr/lib/unused.dylib"],
            ]
        ]))
    }

    /// Values as KSCrash reports carry them (`NSNumber`), not Swift literals.
    private func jsonRoundTrip(_ dict: [String: Any]) -> [String: Any] {
        // swiftlint:disable:next force_try force_cast
        try! JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: dict)) as! [String: Any]
    }

    private func throwSite(processID: Int64 = 42, secondsAfterCrash: TimeInterval = 0) -> ThrowSiteRecorder.ThrowSite {
        .init(processID: processID, date: crashDate.addingTimeInterval(secondsAfterCrash), frames: throwSiteFrames.map(jsonRoundTrip))
    }

    private func crashedStack(_ report: CrashFieldDictionary) throws -> [CrashFieldDictionary] {
        let threads: [CrashFieldDictionary] = try report.value(forKey: .crash, .threads)
        return try threads[0].value(forKey: .backtrace, .contents)
    }

    func testItFillsTheEmptyStackOfACppExceptionWithTheThrowSiteOfTheSameProcess() throws {
        let filled = try XCTUnwrap(DatadogCppThrowSiteFilter(throwSiteFile: URL(fileURLWithPath: "/dev/null")).fill(report: report(), with: throwSite()))
        let stack = try crashedStack(filled)
        XCTAssertEqual(stack.count, 2)
        XCTAssertEqual(try stack[0].value(String.self, forKey: .symbolName), "parseMessage")
        XCTAssertEqual(try stack[0].value(Int64.self, forKey: .objectAddr), 0x1_0000_0000)
    }

    func testItLeavesOtherReportsUnchanged() throws {
        let filter = DatadogCppThrowSiteFilter(throwSiteFile: URL(fileURLWithPath: "/dev/null"))
        XCTAssertNil(try filter.fill(report: report(type: "signal"), with: throwSite()), "not a C++ exception")
        XCTAssertNil(try filter.fill(report: report(processID: 7), with: throwSite()), "another process")
        XCTAssertNil(try filter.fill(report: report(), with: throwSite(secondsAfterCrash: 3_600)), "another crash of a process with the same ID")
        XCTAssertNil(
            try filter.fill(report: report(crashedStack: [["instruction_addr": 0x1_0000_9000, "object_addr": 0x1_0000_0000]]), with: throwSite()),
            "the crash reporter has a stack of its own"
        )
    }

    func testInThePipeline_theThrowSiteImagesAreKeptByMinifyAndTheFileIsConsumed() throws {
        // Given
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("throw-site-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let json: [String: Any] = ["pid": 42, "time": crashDate.timeIntervalSince1970, "frames": throwSiteFrames]
        try JSONSerialization.data(withJSONObject: json).write(to: file)

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
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "A throw site is used once")
    }
}
