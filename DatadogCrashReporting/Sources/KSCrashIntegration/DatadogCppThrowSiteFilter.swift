/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation

// swiftlint:disable duplicate_imports
#if COCOAPODS
import KSCrash
#elseif swift(>=6.0)
internal import KSCrashRecording
#else
@_implementationOnly import KSCrashRecording
#endif
// swiftlint:enable duplicate_imports

/// A KSCrash filter that gives an uncaught C++ exception report the stack of its throw site, when the report has no
/// stack for the crashed thread and a throw site was recorded by the same process (see `ThrowSiteRecorder`).
///
/// The throw site holds raw addresses. Each one is attributed to the report's binary image that contains it, and
/// symbolicated through the same image (same UUID) when it is loaded in the current process.
///
/// It must run after `DatadogTypeSafeFilter` and before `DatadogMinifyFilter`, which keeps only the binary images
/// referenced by the backtraces.
internal final class DatadogCppThrowSiteFilter: NSObject, CrashReportFilter {
    /// A throw site recorded more than this before or after the crash belongs to another crash.
    static let maxTimeDifference: TimeInterval = 60

    private let throwSiteFile: URL

    init(throwSiteFile: URL) {
        self.throwSiteFile = throwSiteFile
        super.init()
    }

    func filterReports(
        _ reports: [CrashReport],
        onCompletion: (([CrashReport]?, (Error)?) -> Void)?
    ) {
        let throwSite = ThrowSiteRecorder.read(from: throwSiteFile)
        let loadedImages = throwSite.map { _ in ThrowSiteRecorder.loadedImages() } ?? [:]
        do {
            let reports = try reports.map { report -> CrashReport in
                guard let dict = report.untypedValue as? CrashFieldDictionary else {
                    throw CrashReportException(description: "KSCrash report untypedValue is not a CrashDictionary")
                }
                guard let throwSite, let filled = try fill(report: dict, with: throwSite, loadedImages: loadedImages) else {
                    return report
                }
                return AnyCrashReport(filled)
            }
            onCompletion?(reports, nil)
        } catch {
            onCompletion?(reports, error)
        }
    }

    /// Returns the report with the throw site as the crashed thread's stack, or `nil` if it does not apply.
    ///
    /// The file is not deleted once used (the current process keeps it open for its own record): a throw site applies
    /// only to a report of the same process and time.
    /// - Parameter loadedImages: the images of the current process, see `ThrowSiteRecorder.loadedImages()`.
    func fill(
        report: CrashFieldDictionary,
        with throwSite: ThrowSiteRecorder.ThrowSite,
        loadedImages: [String: UInt]
    ) throws -> CrashFieldDictionary? {
        guard
            try report.valueIfPresent(String.self, forKey: .crash, .error, .type) == "cpp_exception",
            try report.valueIfPresent(Int64.self, forKey: .system, .processID) == throwSite.processID,
            let timestamp: String = try report.valueIfPresent(forKey: .report, .timestamp),
            let crashDate = Self.date(from: timestamp),
            abs(crashDate.timeIntervalSince(throwSite.date)) <= Self.maxTimeDifference,
            var threads: [CrashFieldDictionary] = try report.valueIfPresent(forKey: .crash, .threads),
            let crashedIndex = try threads.firstIndex(where: { try $0.valueIfPresent(Bool.self, forKey: .crashed) == true })
        else {
            return nil
        }

        let contents: [CrashFieldDictionary] = try threads[crashedIndex].valueIfPresent(forKey: .backtrace, .contents) ?? []
        guard contents.isEmpty else {
            return nil // the crash reporter has a stack of its own
        }
        let images: [CrashFieldDictionary] = try report.valueIfPresent(forKey: .binaryImages) ?? []
        let frames = try throwSite.addresses.map { try Self.frame(at: $0, images: images, loadedImages: loadedImages) }
        let throwSiteFrames = frames.dropFirst(ThrowSiteRecorder.throwSiteIndex(in: frames))
        guard !throwSiteFrames.isEmpty else {
            return nil
        }

        threads[crashedIndex].setValue(
            forKey: .backtrace,
            .contents,
            value: throwSiteFrames.map { CrashFieldDictionary(from: $0) }
        )
        threads[crashedIndex].setValue(forKey: .backtrace, .skipped, value: 0)

        var filled = report
        filled.setValue(forKey: .crash, .threads, value: threads)
        return filled
    }

    /// A frame with KSCrash report frame keys, for a return address of the crashed process.
    static func frame(at address: UInt64, images: [CrashFieldDictionary], loadedImages: [String: UInt]) throws -> [String: Any] {
        var frame: [String: Any] = ["instruction_addr": Int64(bitPattern: address)]
        for image in images {
            guard
                let imageAddress: UInt64 = try image.valueIfPresent(forKey: .imageAddress),
                let imageSize: UInt64 = try image.valueIfPresent(forKey: .imageSize),
                address >= imageAddress, address - imageAddress < imageSize
            else {
                continue
            }
            frame["object_addr"] = Int64(bitPattern: imageAddress)
            if let path: String = try image.valueIfPresent(forKey: .name) {
                frame["object_name"] = (path as NSString).lastPathComponent
            }
            guard
                let uuid: String = try image.valueIfPresent(forKey: .uuid),
                let loadAddress = loadedImages[uuid.uppercased()],
                let localAddress = UnsafeRawPointer(bitPattern: loadAddress + UInt(address - imageAddress))
            else {
                return frame
            }
            var info = Dl_info()
            // A return address points after the call: look up the call itself.
            if dladdr(localAddress - 1, &info) != 0, let symbolAddress = info.dli_saddr, let symbolName = info.dli_sname {
                frame["symbol_addr"] = Int64(bitPattern: imageAddress + UInt64(UInt(bitPattern: symbolAddress) - loadAddress))
                frame["symbol_name"] = String(cString: symbolName)
            }
            return frame
        }
        return frame
    }

    private static func date(from timestamp: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: timestamp) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: timestamp)
    }
}
