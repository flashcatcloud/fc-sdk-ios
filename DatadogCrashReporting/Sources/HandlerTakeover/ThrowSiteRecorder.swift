/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation

/// Records the stack of an uncaught C++ exception at its throw site, for the crash report of the next launch.
///
/// The crash reporter learns the throw site of a C++ exception by intercepting `__cxa_throw`. When another library
/// linked into the app defines its own `__cxa_throw`, the app's throws bypass it and the crash is reported without a
/// stack. But an uncaught exception reaches the terminate handler before the stack is unwound, so the throw site is
/// still on the current stack there: the takeover's terminate handler records it with `record()`, and
/// `DatadogCppThrowSiteFilter` puts it into the crash report when the report has no stack of its own.
///
/// It runs in the terminate handler, on the crashing thread, outside of any signal handler: it may allocate.
internal enum ThrowSiteRecorder {
    /// A recorded throw site.
    struct ThrowSite {
        /// The process that recorded it.
        let processID: Int64
        /// When it was recorded.
        let date: Date
        /// The frames, from the throw site down, with KSCrash report frame keys.
        let frames: [[String: Any]]
    }

    private static var file: URL?

    /// Sets the file `record()` writes to.
    static func prepare(file: URL) {
        self.file = file
    }

    /// Records the current stack, from the first frame below the exception throwing machinery.
    static func record() {
        guard let file else {
            return
        }
        let maxFrames: Int32 = 128
        var addresses = [UnsafeMutableRawPointer?](repeating: nil, count: Int(maxFrames))
        let count = Int(backtrace(&addresses, maxFrames))
        let frames = addresses.prefix(count).compactMap { $0.map(frame(at:)) }

        let json: [String: Any] = [
            "pid": Int64(getpid()),
            "time": Date().timeIntervalSince1970,
            "frames": Array(frames.dropFirst(throwSiteIndex(in: frames)))
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json) {
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Reads the throw site recorded in a file, if any.
    static func read(from file: URL) -> ThrowSite? {
        guard
            let data = try? Data(contentsOf: file),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let processID = (json["pid"] as? NSNumber)?.int64Value,
            let time = (json["time"] as? NSNumber)?.doubleValue,
            let frames = json["frames"] as? [[String: Any]]
        else {
            return nil
        }
        return ThrowSite(processID: processID, date: Date(timeIntervalSince1970: time), frames: frames)
    }

    /// The index of the throw site: the first frame below the C++ runtime's frames (terminate, `__cxa_throw`) and any
    /// `__cxa_throw` defined by another library in between. 0 when no runtime frame is found.
    static func throwSiteIndex(in frames: [[String: Any]]) -> Int {
        guard let runtimeStart = frames.firstIndex(where: isRuntimeFrame) else {
            return 0
        }
        var index = runtimeStart
        while index < frames.count, isRuntimeFrame(frames[index]) || isThrowFrame(frames[index]) {
            index += 1
        }
        return index
    }

    private static func isRuntimeFrame(_ frame: [String: Any]) -> Bool {
        let objectName = frame["object_name"] as? String ?? ""
        return objectName == "libc++abi.dylib" || objectName == "libc++.1.dylib"
    }

    private static func isThrowFrame(_ frame: [String: Any]) -> Bool {
        let symbol = frame["symbol_name"] as? String ?? ""
        return symbol.hasPrefix("__cxa_throw") || symbol.hasPrefix("__cxa_rethrow")
    }

    private static func frame(at address: UnsafeMutableRawPointer) -> [String: Any] {
        var frame: [String: Any] = ["instruction_addr": Int64(Int(bitPattern: address))]
        var info = Dl_info()
        // A return address points after the call: look up the call itself.
        guard dladdr(address - 1, &info) != 0 else {
            return frame
        }
        if let base = info.dli_fbase {
            frame["object_addr"] = Int64(Int(bitPattern: base))
        }
        if let path = info.dli_fname {
            frame["object_name"] = (String(cString: path) as NSString).lastPathComponent
        }
        if let symbolAddress = info.dli_saddr {
            frame["symbol_addr"] = Int64(Int(bitPattern: symbolAddress))
        }
        if let symbolName = info.dli_sname {
            frame["symbol_name"] = String(cString: symbolName)
        }
        return frame
    }
}
