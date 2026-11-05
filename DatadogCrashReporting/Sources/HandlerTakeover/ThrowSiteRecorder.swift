/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation
import MachO

/// Records the stack of an uncaught C++ exception at its throw site, for the crash report of the next launch.
///
/// The crash reporter learns the throw site of a C++ exception by intercepting `__cxa_throw`, which it does by rewriting
/// the symbol pointers of the loaded images. When that does not take effect (another library linked into the app defines
/// its own `__cxa_throw`, or the app's pointer could not be rewritten), the crash reporter has no stack for the thread
/// it was installed on: it only takes the stack at terminate time on other threads. An uncaught exception reaches the
/// terminate handler before the stack is unwound, so the throw site is still on the current stack there. A terminate
/// handler records it with `record()` (the takeover's, or the one `installTerminateHandler(file:)` installs), and
/// `DatadogCppThrowSiteFilter` puts it into the crash report when the report has no stack of its own.
///
/// `record()` runs in the terminate handler, on a crashing thread: it takes the stack with `backtrace()`, as the crash
/// reporter itself does at that point for other threads, and writes the raw return addresses, from preallocated memory,
/// to a file opened beforehand. Every function it calls was resolved or called once by `prepare(file:)`, so none is bound
/// by dyld while terminating. The addresses are symbolicated at the next launch, from the binary images of the crash
/// report.
internal enum ThrowSiteRecorder {
    /// A recorded throw site.
    struct ThrowSite {
        /// The process that recorded it.
        let processID: Int64
        /// When it was recorded.
        let date: Date
        /// The return addresses of the stack at the terminate handler, innermost first.
        let addresses: [UInt64]
    }

    /// The record layout: magic, frame count (`UInt32` each), process ID, time in microseconds since 1970 (`Int64`
    /// each), then `maxFrames` addresses (`UInt64` each). Records have a fixed size, so a record overwrites the previous
    /// one without truncating the file.
    static let magic: UInt32 = 0x5354_4444 // "DDTS"
    static let maxFrames = 128
    static let headerSize = 24
    static let recordSize = headerSize + maxFrames * MemoryLayout<UInt64>.size

    private static var fileDescriptor: Int32 = -1
    private static let buffer = UnsafeMutableRawPointer.allocate(byteCount: recordSize, alignment: MemoryLayout<UInt64>.alignment)

    /// Opens the file `record()` writes to. The record of the previous process stays in it until `record()` runs.
    static func prepare(file: URL) {
        if fileDescriptor >= 0 {
            close(fileDescriptor)
        }
        // Globals are initialized on first access: here, not in the terminate handler.
        _ = (buffer, magic, maxFrames, headerSize, recordSize, terminateState, terminateClaim)
        fileDescriptor = open(file.path, O_WRONLY | O_CREAT | O_CLOEXEC, 0o644)
        // Binds the functions `record()` calls, in case they are bound lazily.
        _ = walkStack(into: buffer + headerSize)
        _ = pwrite(fileDescriptor, buffer, 0, 0)
        _ = getpid()
        var time = timeval()
        gettimeofday(&time, nil)
        _ = (pthread_get_stackaddr_np(pthread_self()), pthread_get_stacksize_np(pthread_self()))
    }

    /// Whether `record()` applies to the exception being terminated on, given its `std::type_info`: not to an
    /// Objective-C exception, which the uncaught exception handler reports with its own stack. The check is the crash
    /// reporter's own (the type name), and it reads two pointers.
    static func shouldRecord(exceptionType: UnsafeRawPointer) -> Bool {
        // `std::type_info` is a vtable pointer followed by a pointer to the type name. On arm64, libc++ sets the top bit
        // of that pointer for a type that may have several `type_info`s; `std::type_info::name()` clears it, as here.
        let namePointer = exceptionType.load(fromByteOffset: MemoryLayout<UnsafeRawPointer>.size, as: UInt.self) & ~(UInt(1) << 63)
        guard let name = UnsafePointer<CChar>(bitPattern: namePointer) else {
            return true
        }
        return strcmp(name, "NSException") != 0
    }

    /// Records the current stack, from the terminate handler down. Allocation-free: see the type's documentation.
    static func record() {
        guard fileDescriptor >= 0 else {
            return
        }
        let count = walkStack(into: buffer + headerSize)
        var time = timeval()
        gettimeofday(&time, nil)
        buffer.storeBytes(of: magic, as: UInt32.self)
        buffer.storeBytes(of: UInt32(max(count, 0)), toByteOffset: 4, as: UInt32.self)
        buffer.storeBytes(of: Int64(getpid()), toByteOffset: 8, as: Int64.self)
        buffer.storeBytes(of: Int64(time.tv_sec) * 1_000_000 + Int64(time.tv_usec), toByteOffset: 16, as: Int64.self)
        _ = pwrite(fileDescriptor, buffer, recordSize, 0)
    }

    /// Strips pointer authentication codes from an arm64 return address, keeping the 47 bits of a user space address,
    /// like the crash reporter does for the frames of its reports.
    static let arm64ReturnAddressMask: UInt = 0x0000_7FFF_FFFF_FFFF

    /// Writes the return addresses of the current stack, innermost first, without allocating: the first ones are in this
    /// function and its callers in the recorder, which `throwSiteIndex(in:)` skips with the runtime's. Returns the count.
    @inline(never)
    private static func walkStack(into addresses: UnsafeMutableRawPointer) -> Int {
        // The memory is raw (see `buffer`): `backtrace()` writes pointers to it, which are read back as `UInt64`.
        let count = Int(backtrace(addresses.assumingMemoryBound(to: UnsafeMutableRawPointer?.self), Int32(maxFrames)))
        #if arch(arm64)
        let words = addresses.assumingMemoryBound(to: UInt64.self)
        for index in 0..<count {
            words[index] &= UInt64(arm64ReturnAddressMask)
        }
        #endif
        return count
    }

    // MARK: - Terminate handler

    /// Installs a C++ terminate handler that records the throw site of an uncaught C++ exception, then calls the handler
    /// it replaced (the crash reporter's). For when the crash handler takeover is not active: the takeover installs its
    /// own. Installed once; later calls do nothing.
    /// - Returns: `true` if the handler is installed.
    @discardableResult
    static func installTerminateHandler(file: URL) -> Bool {
        guard terminateState.pointee.isInstalled == 0 else {
            return true
        }
        guard
            let setTerminate = symbol("_ZSt13set_terminatePFvvE"),
            let currentExceptionType = symbol("__cxa_current_exception_type")
        else {
            return false
        }
        prepare(file: file)
        terminateState.pointee.currentExceptionType = currentExceptionType
        let handler = unsafeBitCast(recordingTerminateHandler, to: UnsafeMutableRawPointer.self)
        terminateState.pointee.previousHandler = unsafeBitCast(setTerminate, to: SetTerminateFunction.self)(handler)
        terminateState.pointee.isInstalled = 1
        return true
    }

    /// For tests: puts back the terminate handler `installTerminateHandler(file:)` replaced and allows a new record. Does
    /// nothing if another handler was installed since, which may call this one: it keeps calling the replaced handler.
    static func uninstallTerminateHandler() {
        guard
            terminateState.pointee.isInstalled != 0,
            let setTerminate = symbol("_ZSt13set_terminatePFvvE"),
            let getTerminate = symbol("_ZSt13get_terminatev")
        else {
            return
        }
        let handler = unsafeBitCast(recordingTerminateHandler, to: UnsafeMutableRawPointer.self)
        guard unsafeBitCast(getTerminate, to: CurrentExceptionTypeFunction.self)() == handler else {
            return
        }
        _ = unsafeBitCast(setTerminate, to: SetTerminateFunction.self)(terminateState.pointee.previousHandler)
        terminateState.pointee.isInstalled = 0
        terminateState.pointee.previousHandler = nil
        terminateClaim.pointee = nil
    }

    /// Records the throw site once per process: the recorder has a single buffer, and another thread terminating at the
    /// same time would mix its stack into the record. Returns whether the calling thread is the one to record.
    fileprivate static func claimRecord() -> Bool {
        var expected: UnsafeRawPointer? = nil
        return _stdlib_atomicCompareExchangeStrongPtr(object: terminateClaim, expected: &expected, desired: UnsafeRawPointer(bitPattern: 1))
    }

    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) // RTLD_DEFAULT
    }

    /// Reads the throw site recorded in a file, if any.
    static func read(from file: URL) -> ThrowSite? {
        guard let data = try? Data(contentsOf: file), data.count >= recordSize else {
            return nil
        }
        return data.withUnsafeBytes { bytes -> ThrowSite? in
            let count = Int(bytes.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
            guard bytes.loadUnaligned(as: UInt32.self) == magic, count <= maxFrames else {
                return nil
            }
            let microseconds = bytes.loadUnaligned(fromByteOffset: 16, as: Int64.self)
            return ThrowSite(
                processID: bytes.loadUnaligned(fromByteOffset: 8, as: Int64.self),
                date: Date(timeIntervalSince1970: TimeInterval(microseconds) / 1_000_000),
                addresses: (0..<count).map { bytes.loadUnaligned(fromByteOffset: headerSize + $0 * 8, as: UInt64.self) }
            )
        }
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

    /// The images loaded in the current process, by UUID (as KSCrash reports write it), with their load address.
    static func loadedImages() -> [String: UInt] {
        var images: [String: UInt] = [:]
        for index in 0..<_dyld_image_count() {
            if let header = _dyld_get_image_header(index), let uuid = uuid(of: header) {
                images[uuid] = UInt(bitPattern: header)
            }
        }
        return images
    }

    private static func uuid(of header: UnsafePointer<mach_header>) -> String? {
        guard header.pointee.magic == MH_MAGIC_64 else {
            return nil
        }
        var command = UnsafeRawPointer(header) + MemoryLayout<mach_header_64>.size
        for _ in 0..<header.pointee.ncmds {
            let loadCommand = command.load(as: load_command.self)
            if loadCommand.cmd == UInt32(LC_UUID) {
                return UUID(uuid: command.loadUnaligned(as: uuid_command.self).uuid).uuidString
            }
            command += Int(loadCommand.cmdsize)
        }
        return nil
    }
}

// MARK: - Terminate handler state

private typealias SetTerminateFunction = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
/// Also the type of `std::get_terminate`.
private typealias CurrentExceptionTypeFunction = @convention(c) () -> UnsafeMutableRawPointer?
private typealias TerminateFunction = @convention(c) () -> Void

/// Plain values only: it is read in the terminate handler.
private struct TerminateState {
    var isInstalled: Int32 = 0
    var currentExceptionType: UnsafeMutableRawPointer?
    var previousHandler: UnsafeMutableRawPointer?
}

private let terminateState: UnsafeMutablePointer<TerminateState> = {
    let pointer = UnsafeMutablePointer<TerminateState>.allocate(capacity: 1)
    pointer.initialize(to: TerminateState())
    return pointer
}()

/// `nil` until a thread claims the record (see `ThrowSiteRecorder.claimRecord()`).
private let terminateClaim: UnsafeMutablePointer<UnsafeRawPointer?> = {
    let pointer = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: 1)
    pointer.initialize(to: nil)
    return pointer
}()

/// Runs when a C++ exception is not caught, or `std::terminate()` is called. Records the throw site of an uncaught C++
/// exception, then hands over to the handler it replaced, unchanged.
private let recordingTerminateHandler: TerminateFunction = {
    let exceptionType = terminateState.pointee.currentExceptionType.flatMap {
        unsafeBitCast($0, to: CurrentExceptionTypeFunction.self)()
    }
    if let exceptionType, ThrowSiteRecorder.shouldRecord(exceptionType: exceptionType), ThrowSiteRecorder.claimRecord() {
        ThrowSiteRecorder.record()
    }
    if let previous = terminateState.pointee.previousHandler {
        unsafeBitCast(previous, to: TerminateFunction.self)()
    }
    abort()
}
