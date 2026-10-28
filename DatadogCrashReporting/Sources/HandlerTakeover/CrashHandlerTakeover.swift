/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation
import MachO

/// Keeps the crash handlers installed by the crash reporter in place once it is installed.
///
/// Another crash reporter in the same app can install its own signal handler, uncaught `NSException` handler or C++
/// terminate handler on top of the SDK's at any time, and then handle crashes first; when its handling stalls or
/// aborts, the crash never reaches the SDK. Once activated, the takeover rewrites the symbol pointers through which the
/// app's own images call `sigaction`, `signal`, `NSSetUncaughtExceptionHandler`, `NSGetUncaughtExceptionHandler`,
/// `std::set_terminate` and `std::get_terminate`. For the crash signals, the uncaught exception handler and the
/// terminate handler owned by the crash reporter:
///
/// - an attempt to install another handler is recorded but not applied;
/// - a query returns the handler last recorded (or the default one), so a caller that checks whether its handler is
///   still installed sees it in place and does not keep re-installing it;
/// - everything else (other signals, handlers the SDK does not own, calls made once a crash is being handled) goes to
///   the real function.
///
/// The crash reporter's signal and uncaught exception handlers are called through handlers of the takeover, which note
/// that a crash is being handled before calling them: from then on, the crash reporter (which restores the previous
/// handlers and re-raises the signal) and the handlers it forwards the crash to are let through. The crash reporter
/// handles Mach exceptions on threads of its own, identified when the takeover is activated.
///
/// The crash reporter still forwards each crash to the handler that was installed before it. When it restores that
/// handler while handling a crash (the first handler installed for the signal from the thread handling the crash),
/// the handler last recorded for the signal, if any, is installed instead: it is the one
/// the other library expects to be installed. So a crash reporter started after the SDK still receives the crash, after
/// the SDK; and one that removed its handler gets the default one installed, rather than its stale handler, which would
/// ignore the signal and let the crash fault again forever.
///
/// An uncaught `NSException` is also passed, once the crash reporter's handler returns, to the uncaught exception
/// handler last recorded, unless it is the one installed before the crash reporter (which the crash reporter already
/// called).
///
/// It also installs a C++ terminate handler that records the throw site of an uncaught C++ exception (see
/// `ThrowSiteRecorder`) before passing it on to the crash reporter's. A terminate handler recorded since is not called:
/// the crash reporter's handler does not return.
///
/// A symbol pointer another library already rewrote to a function of its own (e.g. a wrapper calling the real function)
/// is chained, not clobbered: the replacement calls that function instead of the real one.
///
/// The replacement functions run inside signal handlers of other libraries, so they only use preallocated storage,
/// plain memory accesses and async-signal-safe calls.
internal enum CrashHandlerTakeover {
    /// Whether the takeover is active.
    static var isActive: Bool { state.pointee.isActive != 0 }

    /// Takes over the crash handlers currently installed. Call it right after the crash reporter is installed.
    ///
    /// - Parameters:
    ///   - throwSiteFile: where the throw site of an uncaught C++ exception is written.
    ///   - handlesMachExceptions: whether the crash reporter handles Mach exceptions, on threads of its own.
    ///   - exceptionHandlerBeforeCrashReporter: the uncaught exception handler installed before the crash reporter,
    ///     which the crash reporter calls itself.
    /// - Returns: `true` if the takeover is active.
    @discardableResult
    static func activate(
        throwSiteFile: URL,
        handlesMachExceptions: Bool = false,
        exceptionHandlerBeforeCrashReporter: UnsafeMutableRawPointer? = nil
    ) -> Bool {
        guard state.pointee.isActive == 0 else {
            return true
        }
        guard
            let sigactionFunction = symbol("sigaction"),
            let signalFunction = symbol("signal"),
            let setExceptionHandler = symbol("NSSetUncaughtExceptionHandler"),
            let getExceptionHandler = symbol("NSGetUncaughtExceptionHandler"),
            let setTerminate = symbol("_ZSt13set_terminatePFvvE"),
            let getTerminate = symbol("_ZSt13get_terminatev")
        else {
            return false
        }

        state.pointee.originalSigaction = sigactionFunction
        state.pointee.originalSignal = signalFunction
        state.pointee.originalSetExceptionHandler = setExceptionHandler
        state.pointee.originalGetExceptionHandler = getExceptionHandler
        state.pointee.originalSetTerminate = setTerminate
        state.pointee.originalGetTerminate = getTerminate
        state.pointee.currentExceptionType = symbol("__cxa_current_exception_type")

        // The images implementing the functions called as the originals are left alone: if one is not the system's
        // (e.g. a library wrapping `sigaction`) and calls through its own imports, rewriting them would loop.
        implementingImages = Set(
            [sigactionFunction, signalFunction, setExceptionHandler, getExceptionHandler, setTerminate, getTerminate].compactMap(imageBase)
        )

        state.pointee.isHandlingCrash = 0
        let machThreads = handlesMachExceptions ? crashReporterMachThreads() : []
        state.pointee.machThreads = (machThreads.first ?? 0, machThreads.dropFirst().first ?? 0)
        // Globals are initialized on first access: not in a signal handler.
        _ = (signalTrampolineAddress, exceptionTrampoline, abortingTerminate, foreignActionSlots, foreignActionClaims, foreignActionPublished, crashRestoreRedirected, crashThread)
        atomicExchange(crashThread, 0)

        // Own the crash signals the crash reporter handles. SIGPIPE is left alone: apps commonly ignore it.
        var ownedSignals: UInt32 = 0
        for signal in [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGSYS, SIGTRAP] {
            var action = sigaction()
            _ = callOriginalSigaction(signal, nil, &action)
            let handler = handlerAddress(of: action)
            atomicExchange(foreignActionPublished.advanced(by: Int(signal)), 0)
            atomicExchange(crashRestoreRedirected.advanced(by: Int(signal)), 0)
            guard handler != handlerAddress(of: SIG_DFL), handler != handlerAddress(of: SIG_IGN) else {
                continue
            }
            crashReporterActions[Int(signal)] = action
            var trampoline = action
            trampoline.__sigaction_u.__sa_sigaction = signalTrampoline
            trampoline.sa_flags |= SA_SIGINFO
            if callOriginalSigaction(signal, &trampoline, nil) == 0 {
                ownedSignals |= signalBit(signal)
            }
        }
        state.pointee.ownedSignals = ownedSignals

        state.pointee.crashReporterExceptionHandler = originalGetExceptionHandler()
        if state.pointee.crashReporterExceptionHandler != nil {
            let trampoline = unsafeBitCast(exceptionTrampoline, to: UnsafeMutableRawPointer.self)
            originalSetExceptionHandler(trampoline)
            state.pointee.ownExceptionHandler = trampoline
        } else {
            state.pointee.ownExceptionHandler = nil
        }
        state.pointee.foreignExceptionHandler = nil
        state.pointee.isForeignExceptionHandlerRecorded = 0
        state.pointee.exceptionHandlerBeforeCrashReporter = exceptionHandlerBeforeCrashReporter

        ThrowSiteRecorder.prepare(file: throwSiteFile)
        let terminate = unsafeBitCast(terminateHandler, to: UnsafeMutableRawPointer.self)
        state.pointee.crashReporterTerminate = unsafeBitCast(setTerminate, to: SetPointerFunction.self)(terminate)
        state.pointee.ownTerminate = terminate
        state.pointee.foreignTerminate = nil
        state.pointee.isForeignTerminateRecorded = 0

        state.pointee.isActive = 1

        adoptedCallThroughs = []
        isAdoptingCallThroughs = true
        defer { isAdoptingCallThroughs = false }
        if isImageCallbackRegistered {
            // The callback only runs for images loaded from now on: rewrite the ones already loaded.
            for index in 0..<_dyld_image_count() {
                if let header = _dyld_get_image_header(index) {
                    rebind(rebindings, inImage: header, slide: _dyld_get_image_vmaddr_slide(index))
                }
            }
        } else {
            isImageCallbackRegistered = true
            _ = rebindings // initialized here rather than in the callback, which runs with the loader's lock held
            _dyld_register_func_for_add_image(rebindAddedImage) // also called for every image already loaded
        }
        return true
    }

    /// Ends the takeover: the symbol pointers point at the real functions again and the crash reporter's handlers are
    /// installed directly again. Recorded handlers are dropped, not applied.
    static func deactivate() {
        guard state.pointee.isActive != 0 else {
            return
        }
        state.pointee.isActive = 0
        for signal in 1..<Int32(signalCapacity) where state.pointee.ownedSignals & signalBit(signal) != 0 {
            var current = sigaction()
            _ = callOriginalSigaction(signal, nil, &current)
            if handlerAddress(of: current) == signalTrampolineAddress {
                _ = callOriginalSigaction(signal, crashReporterActions.advanced(by: Int(signal)), nil)
            }
        }
        state.pointee.ownedSignals = 0
        if state.pointee.ownExceptionHandler != nil, originalGetExceptionHandler() == state.pointee.ownExceptionHandler {
            originalSetExceptionHandler(state.pointee.crashReporterExceptionHandler)
        }
        state.pointee.isHandlingCrash = 0
        let originals: [SymbolRebinding] = [
            ("_sigaction", state.pointee.originalSigaction),
            ("_signal", state.pointee.originalSignal),
            ("_NSSetUncaughtExceptionHandler", state.pointee.originalSetExceptionHandler),
            ("_NSGetUncaughtExceptionHandler", state.pointee.originalGetExceptionHandler),
            ("__ZSt13set_terminatePFvvE", state.pointee.originalSetTerminate),
            ("__ZSt13get_terminatev", state.pointee.originalGetTerminate),
        ].compactMap { name, function in function.map { SymbolRebinding(name: name, replacement: UnsafeRawPointer($0)) } }
        for index in 0..<_dyld_image_count() {
            if let header = _dyld_get_image_header(index) {
                rebind(originals, inImage: header, slide: _dyld_get_image_vmaddr_slide(index))
            }
        }
        _ = originalSetTerminate(state.pointee.crashReporterTerminate)
    }

    /// The signal handler installed in front of the crash reporter's.
    static var signalHandler: UInt { signalTrampolineAddress }

    /// The uncaught exception handler installed in front of the crash reporter's.
    static var exceptionHandler: UnsafeMutableRawPointer { unsafeBitCast(exceptionTrampoline, to: UnsafeMutableRawPointer.self) }

    /// The replacements the app's images are rewritten to.
    static let rebindings: [SymbolRebinding] = [
        SymbolRebinding(name: "_sigaction", replacement: unsafeBitCast(sigactionReplacement, to: UnsafeRawPointer.self)),
        SymbolRebinding(name: "_signal", replacement: unsafeBitCast(signalReplacement, to: UnsafeRawPointer.self)),
        SymbolRebinding(name: "_NSSetUncaughtExceptionHandler", replacement: unsafeBitCast(setExceptionHandlerReplacement, to: UnsafeRawPointer.self)),
        SymbolRebinding(name: "_NSGetUncaughtExceptionHandler", replacement: unsafeBitCast(getExceptionHandlerReplacement, to: UnsafeRawPointer.self)),
        SymbolRebinding(name: "__ZSt13set_terminatePFvvE", replacement: unsafeBitCast(setTerminateReplacement, to: UnsafeRawPointer.self)),
        SymbolRebinding(name: "__ZSt13get_terminatev", replacement: unsafeBitCast(getTerminateReplacement, to: UnsafeRawPointer.self)),
    ]

    private static var isImageCallbackRegistered = false

    /// The base addresses of the images implementing the original functions.
    private static var implementingImages: Set<UInt> = []

    /// Whether the symbol pointers rewritten now are looked at for functions of other libraries (while activating).
    private static var isAdoptingCallThroughs = false
    /// The rebindings whose replacement calls a function of another library.
    private static var adoptedCallThroughs: Set<String> = []

    /// Where each replacement finds the function it calls through to.
    private static let callThroughs: [String: WritableKeyPath<TakeoverState, UnsafeMutableRawPointer?>] = [
        "_sigaction": \.originalSigaction,
        "_signal": \.originalSignal,
        "_NSSetUncaughtExceptionHandler": \.originalSetExceptionHandler,
        "_NSGetUncaughtExceptionHandler": \.originalGetExceptionHandler,
        "__ZSt13set_terminatePFvvE": \.originalSetTerminate,
        "__ZSt13get_terminatev": \.originalGetTerminate,
    ]

    /// Rewrites an image, unless it implements one of the original functions.
    fileprivate static func rebind(_ rebindings: [SymbolRebinding], inImage header: UnsafePointer<mach_header>, slide: Int) {
        guard !implementingImages.contains(UInt(bitPattern: header)) else {
            return
        }
        SymbolRebinder.rebind(rebindings, inImage: header, slide: slide) { rebinding, previous in
            if isAdoptingCallThroughs {
                adoptCallThrough(for: rebinding.name, previous: previous, inImage: UInt(bitPattern: header))
            }
        }
    }

    /// Makes `previous`, found in a symbol pointer of an image, the function the replacement calls, when it is a function
    /// of another image than the real one: another library rewrote the pointer to a function of its own. A pointer to
    /// a lazy binding stub of the image itself (never called yet) is not. The first such function found is kept, and
    /// its image is left alone like the images implementing the original functions.
    private static func adoptCallThrough(for name: String, previous: UnsafeRawPointer?, inImage slotImage: UInt) {
        guard
            !adoptedCallThroughs.contains(name),
            let keyPath = callThroughs[name],
            let previous,
            let real = state.pointee[keyPath: keyPath],
            let previousImage = imageBase(of: UnsafeMutableRawPointer(mutating: previous)),
            previousImage != slotImage,
            previousImage != imageBase(of: real)
        else {
            return
        }
        adoptedCallThroughs.insert(name)
        state.pointee[keyPath: keyPath] = UnsafeMutableRawPointer(mutating: previous)
        implementingImages.insert(previousImage)
    }

    /// The handlers of the takeover that are no longer installed: another path than the ones it rewrites (a system
    /// framework, a direct system call) replaced them. Empty when the takeover is not active.
    static func displacedHandlers() -> [String] {
        guard state.pointee.isActive != 0 else {
            return []
        }
        var displaced: [String] = []
        for signal in 1..<Int32(signalCapacity) where state.pointee.ownedSignals & signalBit(signal) != 0 {
            var current = sigaction()
            if callOriginalSigaction(signal, nil, &current) == 0, handlerAddress(of: current) != signalTrampolineAddress {
                displaced.append("signal \(signal)")
            }
        }
        if state.pointee.ownExceptionHandler != nil, originalGetExceptionHandler() != state.pointee.ownExceptionHandler {
            displaced.append("uncaught exception handler")
        }
        if originalGetTerminate() != state.pointee.ownTerminate {
            displaced.append("terminate handler")
        }
        return displaced
    }

    private static func imageBase(of function: UnsafeMutableRawPointer) -> UInt? {
        var info = Dl_info()
        guard dladdr(function, &info) != 0, let base = info.dli_fbase else {
            return nil
        }
        return UInt(bitPattern: base)
    }

    /// The threads on which the crash reporter handles Mach exceptions, named "… Exception Handler (Primary)" and
    /// "… (Secondary)". It starts them while it is installed, and each one names itself once running: they are looked
    /// for until both are found, for at most `machThreadsTimeout`.
    private static func crashReporterMachThreads() -> [thread_t] {
        var found: [thread_t] = []
        let deadline = Date(timeIntervalSinceNow: machThreadsTimeout)
        repeat {
            found = threads(named: " Exception Handler (")
            if found.count >= 2 {
                break
            }
            usleep(1_000)
        } while Date() < deadline
        return found
    }

    static let machThreadsTimeout: TimeInterval = 0.2

    /// The threads of the task whose name contains `name`. Their port names stay valid while the threads run.
    static func threads(named name: String) -> [thread_t] {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else {
            return []
        }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        var threads: [thread_t] = []
        for index in 0..<Int(count) {
            let thread = list[index]
            var buffer = [CChar](repeating: 0, count: 64)
            if let pthread = pthread_from_mach_thread_np(thread),
               pthread_getname_np(pthread, &buffer, buffer.count) == 0,
               String(cString: buffer).contains(name) {
                threads.append(thread)
            }
            mach_port_deallocate(mach_task_self_, thread) // the reference `task_threads` added
        }
        return threads
    }

    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) // RTLD_DEFAULT
    }
}

// MARK: - State

private typealias SigactionFunction = @convention(c) (Int32, UnsafePointer<sigaction>?, UnsafeMutablePointer<sigaction>?) -> Int32
private typealias SignalFunction = @convention(c) (Int32, UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
private typealias SetPointerFunction = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
private typealias SetVoidFunction = @convention(c) (UnsafeMutableRawPointer?) -> Void
private typealias GetPointerFunction = @convention(c) () -> UnsafeMutableRawPointer?
private typealias TerminateFunction = @convention(c) () -> Void
private typealias ExceptionHandlerFunction = @convention(c) (NSException) -> Void
private typealias SignalActionFunction = @convention(c) (Int32, UnsafeMutablePointer<__siginfo>?, UnsafeMutableRawPointer?) -> Void

/// Plain values only: it is read from signal handlers.
private struct TakeoverState {
    var isActive: Int32 = 0
    /// Set once a crash reaches the crash reporter's handlers; never reset while active.
    var isHandlingCrash: Int32 = 0
    var ownedSignals: UInt32 = 0
    var originalSigaction: UnsafeMutableRawPointer?
    var originalSignal: UnsafeMutableRawPointer?
    var originalSetExceptionHandler: UnsafeMutableRawPointer?
    var originalGetExceptionHandler: UnsafeMutableRawPointer?
    var originalSetTerminate: UnsafeMutableRawPointer?
    var originalGetTerminate: UnsafeMutableRawPointer?
    var currentExceptionType: UnsafeMutableRawPointer?
    var crashReporterExceptionHandler: UnsafeMutableRawPointer?
    var ownExceptionHandler: UnsafeMutableRawPointer?
    var foreignExceptionHandler: UnsafeMutableRawPointer?
    var isForeignExceptionHandlerRecorded: Int32 = 0
    var exceptionHandlerBeforeCrashReporter: UnsafeMutableRawPointer?
    var ownTerminate: UnsafeMutableRawPointer?
    var crashReporterTerminate: UnsafeMutableRawPointer?
    var foreignTerminate: UnsafeMutableRawPointer?
    var isForeignTerminateRecorded: Int32 = 0
    /// The threads on which the crash reporter handles Mach exceptions (0 for none), set before activation.
    var machThreads: (thread_t, thread_t) = (0, 0)
}

private let signalCapacity = 32 // signals are numbered 1...31 on Darwin

private let state: UnsafeMutablePointer<TakeoverState> = {
    let pointer = UnsafeMutablePointer<TakeoverState>.allocate(capacity: 1)
    pointer.initialize(to: TakeoverState())
    return pointer
}()

/// The crash reporter's action for each owned signal.
private let crashReporterActions: UnsafeMutablePointer<sigaction> = {
    let pointer = UnsafeMutablePointer<sigaction>.allocate(capacity: signalCapacity)
    pointer.initialize(repeating: sigaction(), count: signalCapacity)
    return pointer
}()

/// The actions other callers tried to install for each owned signal. Each one is recorded in a slot of its own
/// (`slotsPerSignal` slots per signal, used in turn), then the slot is published. Every access is atomic, and a slot's
/// sequence number is odd while it is written: a reader, e.g. the crash-time redirect interrupting a recording on the
/// same thread, copies a complete action or retries.
private let slotsPerSignal = 8
/// The words of each slot.
private enum SlotWord: Int, CaseIterable {
    case sequence, handler, maskAndFlags
}

private let foreignActionSlots = atomicWords(count: signalCapacity * slotsPerSignal * SlotWord.allCases.count)
/// How many slots were claimed for each signal (as an integer).
private let foreignActionClaims = atomicWords(count: signalCapacity)
/// The index of the slot of the last action recorded for each signal, plus one; `nil` if none.
private let foreignActionPublished = atomicWords(count: signalCapacity)

/// Whether the first handler installed for each owned signal while handling a crash was replaced by the recorded one
/// (non-`nil`).
private let crashRestoreRedirected = atomicWords(count: signalCapacity)

private func atomicWords(count: Int) -> UnsafeMutablePointer<UnsafeRawPointer?> {
    let pointer = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: count)
    pointer.initialize(repeating: nil, count: count)
    return pointer
}

// MARK: - Atomics (async-signal-safe)

// A compare-and-swap is a single sequentially consistent instruction sequence, without a lock: it is safe in a signal
// handler, including one interrupting another access on the same thread. Integers are stored as pointer bit patterns.

private func atomicLoad(_ word: UnsafeMutablePointer<UnsafeRawPointer?>) -> UInt {
    var expected: UnsafeRawPointer? = nil
    _ = _stdlib_atomicCompareExchangeStrongPtr(object: word, expected: &expected, desired: nil) // fails unless nil
    return UInt(bitPattern: expected)
}

@discardableResult
private func atomicExchange(_ word: UnsafeMutablePointer<UnsafeRawPointer?>, _ value: UInt) -> UInt {
    var expected = UnsafeRawPointer(bitPattern: atomicLoad(word))
    while !_stdlib_atomicCompareExchangeStrongPtr(object: word, expected: &expected, desired: UnsafeRawPointer(bitPattern: value)) {}
    return UInt(bitPattern: expected)
}

/// Sets the word to `desired` if it is `expected`. Returns whether it did.
private func atomicCompareExchange(_ word: UnsafeMutablePointer<UnsafeRawPointer?>, _ expected: UInt, _ desired: UInt) -> Bool {
    var expected = UnsafeRawPointer(bitPattern: expected)
    return _stdlib_atomicCompareExchangeStrongPtr(object: word, expected: &expected, desired: UnsafeRawPointer(bitPattern: desired))
}

/// Increments the word. Returns the value before the increment.
@discardableResult
private func atomicIncrement(_ word: UnsafeMutablePointer<UnsafeRawPointer?>) -> UInt {
    var expected = UnsafeRawPointer(bitPattern: atomicLoad(word))
    while !_stdlib_atomicCompareExchangeStrongPtr(
        object: word,
        expected: &expected,
        desired: UnsafeRawPointer(bitPattern: UInt(bitPattern: expected) &+ 1)
    ) {}
    return UInt(bitPattern: expected)
}

private func slotWord(_ slot: Int, _ word: SlotWord) -> UnsafeMutablePointer<UnsafeRawPointer?> {
    foreignActionSlots.advanced(by: slot * SlotWord.allCases.count + word.rawValue)
}

/// Records the action another caller tried to install for a signal.
private func recordForeignAction(_ action: sigaction, for signal: Int32) {
    // Take a slot no other record is writing (its sequence is even) by making its sequence odd; a slot being written,
    // e.g. by a record this call interrupts on the same thread, is skipped rather than waited for.
    var slot: Int
    var sequence: UInt
    repeat {
        let claim = atomicIncrement(foreignActionClaims.advanced(by: Int(signal)))
        slot = Int(signal) * slotsPerSignal + Int(claim % UInt(slotsPerSignal))
        sequence = atomicLoad(slotWord(slot, .sequence))
    } while sequence % 2 != 0 || !atomicCompareExchange(slotWord(slot, .sequence), sequence, sequence + 1)
    atomicExchange(slotWord(slot, .handler), handlerAddress(of: action))
    atomicExchange(slotWord(slot, .maskAndFlags), UInt(action.sa_mask) | UInt(UInt32(bitPattern: action.sa_flags)) << 32)
    atomicIncrement(slotWord(slot, .sequence)) // even: complete
    atomicExchange(foreignActionPublished.advanced(by: Int(signal)), UInt(slot + 1))
}

/// The last action recorded for a signal, if any.
internal func recordedForeignAction(for signal: Int32) -> sigaction? {
    // A slot is rewritten only after `slotsPerSignal` more records: retrying covers concurrent records, and an
    // unbounded wait is never needed.
    for _ in 0..<64 {
        let published = atomicLoad(foreignActionPublished.advanced(by: Int(signal)))
        guard published != 0 else {
            return nil
        }
        let slot = Int(published) - 1
        let sequence = atomicLoad(slotWord(slot, .sequence))
        let handler = atomicLoad(slotWord(slot, .handler))
        let maskAndFlags = atomicLoad(slotWord(slot, .maskAndFlags))
        guard sequence % 2 == 0, atomicLoad(slotWord(slot, .sequence)) == sequence else {
            continue
        }
        var action = sigaction()
        action.__sigaction_u = unsafeBitCast(handler, to: __sigaction_u.self)
        action.sa_mask = sigset_t(truncatingIfNeeded: maskAndFlags)
        action.sa_flags = Int32(bitPattern: UInt32(truncatingIfNeeded: maskAndFlags >> 32))
        return action
    }
    return nil
}

// MARK: - Helpers (async-signal-safe)

private func signalBit(_ signal: Int32) -> UInt32 {
    signal > 0 && signal < Int32(signalCapacity) ? UInt32(1) << UInt32(signal - 1) : 0
}

private func handlerAddress(of action: sigaction) -> UInt {
    unsafeBitCast(action.__sigaction_u, to: UInt.self)
}

private func handlerAddress(of handler: sig_t?) -> UInt {
    unsafeBitCast(handler, to: UInt.self)
}

private func callOriginalSigaction(_ signal: Int32, _ action: UnsafePointer<sigaction>?, _ oldAction: UnsafeMutablePointer<sigaction>?) -> Int32 {
    guard let function = state.pointee.originalSigaction else {
        return -1
    }
    return unsafeBitCast(function, to: SigactionFunction.self)(signal, action, oldAction)
}

private func originalSignal(_ signal: Int32, _ handler: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    guard let function = state.pointee.originalSignal else {
        return UnsafeMutableRawPointer(bitPattern: -1) // SIG_ERR
    }
    return unsafeBitCast(function, to: SignalFunction.self)(signal, handler)
}

private func originalGetExceptionHandler() -> UnsafeMutableRawPointer? {
    state.pointee.originalGetExceptionHandler.flatMap { unsafeBitCast($0, to: GetPointerFunction.self)() }
}

private func originalSetExceptionHandler(_ handler: UnsafeMutableRawPointer?) {
    state.pointee.originalSetExceptionHandler.map { unsafeBitCast($0, to: SetVoidFunction.self)(handler) }
}

private func originalGetTerminate() -> UnsafeMutableRawPointer? {
    state.pointee.originalGetTerminate.flatMap { unsafeBitCast($0, to: GetPointerFunction.self)() }
}

private func originalSetTerminate(_ handler: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    state.pointee.originalSetTerminate.flatMap { unsafeBitCast($0, to: SetPointerFunction.self)(handler) }
}

/// The calling thread. `mach_thread_self()` adds a reference to the port, released right away: the port name stays
/// valid while the thread runs.
private func currentThread() -> thread_t {
    let thread = mach_thread_self()
    mach_port_deallocate(mach_task_self_, thread)
    return thread
}

/// Whether this is one of the threads on which the crash reporter handles Mach exceptions.
private func isCrashReporterMachThread(_ thread: thread_t) -> Bool {
    let machThreads = state.pointee.machThreads
    return thread != 0 && (thread == machThreads.0 || thread == machThreads.1)
}

/// The first thread that reached the crash reporter's handlers (0 until then), set atomically.
private let crashThread = atomicWords(count: 1)

/// Marks that a crash is being handled, on the calling thread. Called by the handlers in front of the crash reporter's.
private func noteCrash() {
    state.pointee.isHandlingCrash = 1
    _ = atomicCompareExchange(crashThread, 0, UInt(currentThread()))
}

/// Whether a crash is being handled: it reached the crash reporter's handlers, or this is one of the threads on which
/// the crash reporter handles Mach exceptions.
private func isHandlingCrash() -> Bool {
    state.pointee.isHandlingCrash != 0 || isCrashReporterMachThread(currentThread())
}

/// Whether the calling thread is the one the crash reporter handles the crash on.
private func isCrashHandlingThread() -> Bool {
    let thread = currentThread()
    return isCrashReporterMachThread(thread) || (state.pointee.isHandlingCrash != 0 && UInt(thread) == atomicLoad(crashThread))
}

/// Whether the takeover applies to a call about this signal: it is active, owns the signal, its handler is still the
/// one installed, and no crash is being handled.
private func isGuarding(signal: Int32) -> Bool {
    let bit = signalBit(signal)
    guard state.pointee.isActive != 0, bit != 0, state.pointee.ownedSignals & bit != 0, !isHandlingCrash() else {
        return false
    }
    var current = sigaction()
    _ = callOriginalSigaction(signal, nil, &current)
    return handlerAddress(of: current) == signalTrampolineAddress
}

/// The action a caller sees as installed: the last one it recorded, or the default one.
private func recordedAction(for signal: Int32) -> sigaction {
    recordedForeignAction(for: signal) ?? sigaction()
}

// MARK: - Replacements

/// The action recorded for this signal, if a handler installed for it is the crash reporter restoring the handler it
/// saved, while handling a crash, and another one was recorded since: the first one installed for the signal once a
/// crash is being handled.
private func crashRestoreRedirect(signal: Int32) -> sigaction? {
    let bit = signalBit(signal)
    guard
        state.pointee.isActive != 0, bit != 0, state.pointee.ownedSignals & bit != 0,
        let recorded = recordedForeignAction(for: signal),
        isCrashHandlingThread(),
        atomicCompareExchange(crashRestoreRedirected.advanced(by: Int(signal)), 0, 1)
    else {
        return nil
    }
    return recorded
}

private let sigactionReplacement: SigactionFunction = { signal, action, oldAction in
    guard isGuarding(signal: signal) else {
        if action != nil, var recorded = crashRestoreRedirect(signal: signal) {
            return callOriginalSigaction(signal, &recorded, oldAction)
        }
        return callOriginalSigaction(signal, action, oldAction)
    }
    let previous = recordedAction(for: signal)
    if let action {
        recordForeignAction(action.pointee, for: signal)
    }
    oldAction?.pointee = previous
    return 0
}

private let signalReplacement: SignalFunction = { signal, handler in
    guard isGuarding(signal: signal) else {
        return originalSignal(signal, handler)
    }
    let previous = recordedAction(for: signal)
    var action = sigaction()
    action.__sigaction_u = unsafeBitCast(handler, to: __sigaction_u.self)
    recordForeignAction(action, for: signal)
    return unsafeBitCast(previous.__sigaction_u, to: UnsafeMutableRawPointer?.self)
}

private func isGuardingExceptionHandler() -> Bool {
    guard state.pointee.isActive != 0, !isHandlingCrash() else {
        return false
    }
    let current = originalGetExceptionHandler()
    return current != nil && current == state.pointee.ownExceptionHandler
}

private let setExceptionHandlerReplacement: SetVoidFunction = { handler in
    guard isGuardingExceptionHandler() else {
        return originalSetExceptionHandler(handler)
    }
    state.pointee.foreignExceptionHandler = handler
    state.pointee.isForeignExceptionHandlerRecorded = 1
}

private let getExceptionHandlerReplacement: GetPointerFunction = {
    guard isGuardingExceptionHandler() else {
        return originalGetExceptionHandler()
    }
    return state.pointee.foreignExceptionHandler
}

private func isGuardingTerminate() -> Bool {
    guard state.pointee.isActive != 0, !isHandlingCrash() else {
        return false
    }
    let current = originalGetTerminate()
    return current == state.pointee.ownTerminate
}

/// What a caller sees as the terminate handler when none was recorded: one that aborts, as the default one does.
private let abortingTerminate: TerminateFunction = { abort() }

private func recordedTerminate() -> UnsafeMutableRawPointer? {
    state.pointee.isForeignTerminateRecorded != 0
        ? state.pointee.foreignTerminate
        : unsafeBitCast(abortingTerminate, to: UnsafeMutableRawPointer.self)
}

private let setTerminateReplacement: SetPointerFunction = { handler in
    guard isGuardingTerminate() else {
        return originalSetTerminate(handler)
    }
    let previous = recordedTerminate()
    state.pointee.foreignTerminate = handler
    state.pointee.isForeignTerminateRecorded = 1
    return previous
}

private let getTerminateReplacement: GetPointerFunction = {
    guard isGuardingTerminate() else {
        return originalGetTerminate()
    }
    return recordedTerminate()
}

// MARK: - Handlers

/// Installed in front of the crash reporter's signal handler.
private let signalTrampoline: SignalActionFunction = { signal, info, context in
    noteCrash()
    guard signal > 0, signal < Int32(signalCapacity) else {
        return
    }
    let action = crashReporterActions[Int(signal)]
    if action.sa_flags & SA_SIGINFO != 0 {
        action.__sigaction_u.__sa_sigaction?(signal, info, context)
    } else {
        action.__sigaction_u.__sa_handler?(signal)
    }
}

private let signalTrampolineAddress = unsafeBitCast(signalTrampoline, to: UInt.self)

/// Installed in front of the crash reporter's uncaught exception handler.
private let exceptionTrampoline: ExceptionHandlerFunction = { exception in
    noteCrash()
    if let handler = state.pointee.crashReporterExceptionHandler {
        unsafeBitCast(handler, to: ExceptionHandlerFunction.self)(exception)
    }
    // The handler another library installed since the crash reporter, which it expects to be called.
    if state.pointee.isForeignExceptionHandlerRecorded != 0,
       let foreign = state.pointee.foreignExceptionHandler,
       foreign != state.pointee.exceptionHandlerBeforeCrashReporter,
       foreign != state.pointee.crashReporterExceptionHandler,
       foreign != state.pointee.ownExceptionHandler {
        unsafeBitCast(foreign, to: ExceptionHandlerFunction.self)(exception)
    }
}

/// Runs when a C++ exception is not caught, or `std::terminate()` is called.
private let terminateHandler: TerminateFunction = {
    let exceptionType = state.pointee.currentExceptionType.flatMap {
        unsafeBitCast($0, to: GetPointerFunction.self)()
    }
    guard let exceptionType else {
        // No exception: abort, so the crash is recorded with the current stack as any other abort.
        abort()
    }
    noteCrash()
    // The exception was not caught, so the stack has not been unwound: the throw site is still on it.
    if ThrowSiteRecorder.shouldRecord(exceptionType: exceptionType) {
        ThrowSiteRecorder.record()
    }
    if let crashReporterTerminate = state.pointee.crashReporterTerminate {
        unsafeBitCast(crashReporterTerminate, to: TerminateFunction.self)()
    }
    abort()
}

/// Called by dyld for every image, already loaded or loaded later.
internal let rebindAddedImage: @convention(c) (UnsafePointer<mach_header>?, Int) -> Void = { header, slide in
    guard state.pointee.isActive != 0, let header else {
        return
    }
    CrashHandlerTakeover.rebind(CrashHandlerTakeover.rebindings, inImage: header, slide: slide)
}
