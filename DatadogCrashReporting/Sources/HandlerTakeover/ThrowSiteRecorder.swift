/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation
import MachO

/// Records the stack of an uncaught C++ exception at its throw site, for the crash report of the next launch.
///
/// The crash reporter learns the throw site of a C++ exception by intercepting `__cxa_throw`. When another library
/// linked into the app defines its own `__cxa_throw`, the app's throws bypass it and the crash is reported without a
/// stack. But an uncaught exception reaches the terminate handler before the stack is unwound, so the throw site is
/// still on the current stack there: the takeover's terminate handler records it with `record()`, and
/// `DatadogCppThrowSiteFilter` puts it into the crash report when the report has no stack of its own.
///
/// `record()` runs in the terminate handler, on a crashing thread that may hold any lock (e.g. the allocator's or the
/// unwinder's): it walks the frame pointers of the current stack (which arm64 and x86_64 code keeps), without locks or
/// allocation, and writes the raw return addresses, from preallocated memory, to a file opened beforehand. Every function
/// it calls was resolved or called once by `prepare(file:)`, so none is bound by dyld while terminating. The addresses
/// are symbolicated at the next launch, from the binary images of the crash report.
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

    private typealias GetContextFunction = @convention(c) (UnsafeMutableRawPointer) -> Int32
    /// `getcontext()`, which saves the caller's registers, including its frame pointer. Its declaration is not visible to
    /// Swift (it needs `_XOPEN_SOURCE`).
    private static var getContext: GetContextFunction?
    /// A `ucontext_t` followed by the machine context `getcontext()` points it at, which is 16-byte aligned.
    private static let contextSize = (MemoryLayout<ucontext_t>.size + 15) / 16 * 16 + MemoryLayout<mcontext_t.Pointee>.size
    private static let context = UnsafeMutableRawPointer.allocate(byteCount: contextSize, alignment: 16)

    /// Opens the file `record()` writes to. The record of the previous process stays in it until `record()` runs.
    static func prepare(file: URL) {
        if fileDescriptor >= 0 {
            close(fileDescriptor)
        }
        // Globals are initialized on first access: here, not in the terminate handler.
        _ = (buffer, magic, maxFrames, headerSize, recordSize, context, contextSize)
        getContext = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "getcontext").map { unsafeBitCast($0, to: GetContextFunction.self) }
        fileDescriptor = open(file.path, O_WRONLY | O_CREAT | O_CLOEXEC, 0o644)
        // Binds the functions `record()` calls, in case they are bound lazily.
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
        // `std::type_info` is a vtable pointer followed by a pointer to the type name.
        guard let name = exceptionType.load(fromByteOffset: MemoryLayout<UnsafeRawPointer>.size, as: UnsafePointer<CChar>?.self) else {
            return true
        }
        return strcmp(name, "NSException") != 0
    }

    /// Records the current stack, from the terminate handler down. Allocation-free: see the type's documentation.
    static func record() {
        guard fileDescriptor >= 0 else {
            return
        }
        let count = walkStack(into: (buffer + headerSize).assumingMemoryBound(to: UInt64.self))
        var time = timeval()
        gettimeofday(&time, nil)
        buffer.storeBytes(of: magic, as: UInt32.self)
        buffer.storeBytes(of: UInt32(max(count, 0)), toByteOffset: 4, as: UInt32.self)
        buffer.storeBytes(of: Int64(getpid()), toByteOffset: 8, as: Int64.self)
        buffer.storeBytes(of: Int64(time.tv_sec) * 1_000_000 + Int64(time.tv_usec), toByteOffset: 16, as: Int64.self)
        _ = pwrite(fileDescriptor, buffer, recordSize, 0)
    }

    /// Writes the return addresses of the current stack, innermost first, from the caller of `getcontext()` (this function)
    /// up. Each frame record is the pair of the caller's frame pointer and the return address, where the frame pointer
    /// points; a record is followed only while it lies on this thread's stack, above the previous one. Returns the count.
    @inline(never)
    private static func walkStack(into addresses: UnsafeMutablePointer<UInt64>) -> Int {
        guard let getContext, getContext(context) == 0 else {
            return 0
        }
        guard let machineContext = context.assumingMemoryBound(to: ucontext_t.self).pointee.uc_mcontext else {
            return 0
        }
        #if arch(arm64)
        var framePointer = UInt(machineContext.pointee.__ss.__fp)
        let returnAddressMask: UInt = 0x0000_000F_FFFF_FFFF // strips pointer authentication codes, like the crash reporter
        #elseif arch(x86_64)
        var framePointer = UInt(machineContext.pointee.__ss.__rbp)
        let returnAddressMask = UInt.max
        #else
        return 0
        #endif
        let thread = pthread_self()
        let stackTop = UInt(bitPattern: pthread_get_stackaddr_np(thread))
        let stackBottom = stackTop &- UInt(pthread_get_stacksize_np(thread))
        let recordSize = UInt(2 * MemoryLayout<UInt>.size)
        var count = 0
        while count < maxFrames,
              framePointer >= stackBottom,
              framePointer <= stackTop &- recordSize,
              framePointer % UInt(MemoryLayout<UInt>.alignment) == 0,
              let record = UnsafePointer<UInt>(bitPattern: framePointer) {
            let returnAddress = record[1] & returnAddressMask
            guard returnAddress != 0 else {
                break
            }
            addresses[count] = UInt64(returnAddress)
            count += 1
            let callerFramePointer = record[0]
            guard callerFramePointer > framePointer else {
                break
            }
            framePointer = callerFramePointer
        }
        return count
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
