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
/// handles Mach exceptions on threads of its own, recognized by their name.
///
/// The crash reporter still forwards each crash to the handler that was installed before it. When it restores that
/// handler while handling a crash, the handler last recorded for the signal, if any, is installed instead: it is the one
/// the other library expects to be installed. So a crash reporter started after the SDK still receives the crash, after
/// the SDK; and one that removed its handler gets the default one installed, rather than its stale handler, which would
/// ignore the signal and let the crash fault again forever.
///
/// It also installs a C++ terminate handler that records the throw site of an uncaught C++ exception (see
/// `ThrowSiteRecorder`) before passing it on to the crash reporter's.
///
/// The replacement functions run inside signal handlers of other libraries, so they only use preallocated storage,
/// plain memory accesses and async-signal-safe calls.
internal enum CrashHandlerTakeover {
    /// Whether the takeover is active.
    static var isActive: Bool { state.pointee.isActive != 0 }

    /// Takes over the crash handlers currently installed. Call it right after the crash reporter is installed.
    ///
    /// - Parameter throwSiteFile: where the throw site of an uncaught C++ exception is written.
    /// - Returns: `true` if the takeover is active.
    @discardableResult
    static func activate(throwSiteFile: URL) -> Bool {
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
        // Globals are initialized on first access: not in a signal handler.
        _ = (signalTrampolineAddress, exceptionTrampoline, abortingTerminate, foreignActions, foreignActionRecorded, crashRestoreRedirected)

        // Own the crash signals the crash reporter handles. SIGPIPE is left alone: apps commonly ignore it.
        var ownedSignals: UInt32 = 0
        for signal in [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGSYS, SIGTRAP] {
            var action = sigaction()
            _ = callOriginalSigaction(signal, nil, &action)
            let handler = handlerAddress(of: action)
            foreignActionRecorded[Int(signal)] = 0
            crashRestoreRedirected[Int(signal)] = 0
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

        ThrowSiteRecorder.prepare(file: throwSiteFile)
        let terminate = unsafeBitCast(terminateHandler, to: UnsafeMutableRawPointer.self)
        state.pointee.crashReporterTerminate = unsafeBitCast(setTerminate, to: SetPointerFunction.self)(terminate)
        state.pointee.ownTerminate = terminate
        state.pointee.foreignTerminate = nil
        state.pointee.isForeignTerminateRecorded = 0

        state.pointee.isActive = 1

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

    /// Rewrites an image, unless it implements one of the original functions.
    fileprivate static func rebind(_ rebindings: [SymbolRebinding], inImage header: UnsafePointer<mach_header>, slide: Int) {
        guard !implementingImages.contains(UInt(bitPattern: header)) else {
            return
        }
        SymbolRebinder.rebind(rebindings, inImage: header, slide: slide)
    }

    private static func imageBase(of function: UnsafeMutableRawPointer) -> UInt? {
        var info = Dl_info()
        guard dladdr(function, &info) != 0, let base = info.dli_fbase else {
            return nil
        }
        return UInt(bitPattern: base)
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
    var ownTerminate: UnsafeMutableRawPointer?
    var crashReporterTerminate: UnsafeMutableRawPointer?
    var foreignTerminate: UnsafeMutableRawPointer?
    var isForeignTerminateRecorded: Int32 = 0
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

/// The last action another caller tried to install for each owned signal.
private let foreignActions: UnsafeMutablePointer<sigaction> = {
    let pointer = UnsafeMutablePointer<sigaction>.allocate(capacity: signalCapacity)
    pointer.initialize(repeating: sigaction(), count: signalCapacity)
    return pointer
}()

private let foreignActionRecorded: UnsafeMutablePointer<Int32> = {
    let pointer = UnsafeMutablePointer<Int32>.allocate(capacity: signalCapacity)
    pointer.initialize(repeating: 0, count: signalCapacity)
    return pointer
}()

/// Whether the first handler installed for each owned signal while handling a crash was replaced by the recorded one.
private let crashRestoreRedirected: UnsafeMutablePointer<Int32> = {
    let pointer = UnsafeMutablePointer<Int32>.allocate(capacity: signalCapacity)
    pointer.initialize(repeating: 0, count: signalCapacity)
    return pointer
}()

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

/// Whether a crash is being handled: it reached the crash reporter's handlers, or this is one of the threads on which
/// the crash reporter handles Mach exceptions (named "… Exception Handler (Primary)" and "… (Secondary)").
private func isHandlingCrash() -> Bool {
    if state.pointee.isHandlingCrash != 0 {
        return true
    }
    var name: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0, 0, 0, 0, 0)
    return withUnsafeMutableBytes(of: &name) { buffer in
        guard let base = buffer.baseAddress?.assumingMemoryBound(to: CChar.self) else {
            return false
        }
        // The name of the calling thread is read without locking.
        guard pthread_getname_np(pthread_self(), base, buffer.count - 1) == 0 else {
            return false
        }
        return strstr(base, " Exception Handler (") != nil
    }
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
    foreignActionRecorded[Int(signal)] != 0 ? foreignActions[Int(signal)] : sigaction()
}

// MARK: - Replacements

/// Whether a handler installed for this signal is the crash reporter restoring the handler it saved, while handling a
/// crash, and another one was recorded since: the first one installed for the signal once a crash is being handled.
private func isCrashRestoreToRedirect(signal: Int32) -> Bool {
    let bit = signalBit(signal)
    guard
        state.pointee.isActive != 0, bit != 0, state.pointee.ownedSignals & bit != 0,
        foreignActionRecorded[Int(signal)] != 0, crashRestoreRedirected[Int(signal)] == 0,
        isHandlingCrash()
    else {
        return false
    }
    crashRestoreRedirected[Int(signal)] = 1
    return true
}

private let sigactionReplacement: SigactionFunction = { signal, action, oldAction in
    guard isGuarding(signal: signal) else {
        if action != nil, isCrashRestoreToRedirect(signal: signal) {
            return callOriginalSigaction(signal, foreignActions.advanced(by: Int(signal)), oldAction)
        }
        return callOriginalSigaction(signal, action, oldAction)
    }
    let previous = recordedAction(for: signal)
    if let action {
        foreignActions[Int(signal)] = action.pointee
        foreignActionRecorded[Int(signal)] = 1
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
    foreignActions[Int(signal)] = action
    foreignActionRecorded[Int(signal)] = 1
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
    state.pointee.isHandlingCrash = 1
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
    state.pointee.isHandlingCrash = 1
    if let handler = state.pointee.crashReporterExceptionHandler {
        unsafeBitCast(handler, to: ExceptionHandlerFunction.self)(exception)
    }
}

/// Runs when a C++ exception is not caught, or `std::terminate()` is called.
private let terminateHandler: TerminateFunction = {
    let exceptionType = state.pointee.currentExceptionType.flatMap {
        unsafeBitCast($0, to: GetPointerFunction.self)()
    }
    guard exceptionType != nil else {
        // No exception: abort, so the crash is recorded with the current stack as any other abort.
        abort()
    }
    state.pointee.isHandlingCrash = 1
    // The exception was not caught, so the stack has not been unwound: the throw site is still on it.
    ThrowSiteRecorder.record()
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
