/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import XCTest
import MachO
@testable import DatadogCrashReporting

private typealias RealSigaction = @convention(c) (Int32, UnsafePointer<sigaction>?, UnsafeMutablePointer<sigaction>?) -> Int32
private typealias PointerGetter = @convention(c) () -> UnsafeMutableRawPointer?
private typealias CExceptionHandler = @convention(c) (NSException) -> Void
private typealias PointerSetter = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?

/// The real functions, which the takeover does not rewrite for `dlsym` lookups.
private let realSigaction = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sigaction"), to: RealSigaction.self)
private let realGetExceptionHandler = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "NSGetUncaughtExceptionHandler"), to: PointerGetter.self)
private let realGetTerminate = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_ZSt13get_terminatev"), to: PointerGetter.self)

private var ownHandlerCalls = 0
private var ownExceptionHandlerCalls = 0
private func ownHandler(_ signal: Int32) { ownHandlerCalls += 1 }
private func foreignHandler(_ signal: Int32) {}
private func otherHandler(_ signal: Int32) {}
private func ownExceptionHandler(_ exception: NSException) { ownExceptionHandlerCalls += 1 }
private func foreignExceptionHandler(_ exception: NSException) {}
private let foreignTerminate: @convention(c) () -> Void = { abort() }

private func address(of handler: sig_t?) -> UInt { unsafeBitCast(handler, to: UInt.self) }
private func address(of action: sigaction) -> UInt { unsafeBitCast(action.__sigaction_u, to: UInt.self) }

private func action(_ handler: sig_t?) -> sigaction {
    var action = sigaction()
    action.__sigaction_u = unsafeBitCast(handler, to: __sigaction_u.self)
    return action
}

/// The handler really installed for a signal, bypassing the takeover.
private func installedHandler(_ signal: Int32) -> UInt {
    var current = sigaction()
    _ = realSigaction(signal, nil, &current)
    return address(of: current)
}

class CrashHandlerTakeoverTests: XCTestCase {
    // SIGFPE and SIGSYS are owned by the takeover but not used by the test runner.
    private let ownedSignal = SIGFPE
    private var savedActions: [Int32: sigaction] = [:]
    private var savedExceptionHandler: CExceptionHandler?
    private var throwSiteFile: URL! // swiftlint:disable:this implicitly_unwrapped_optional

    override func setUp() {
        super.setUp()
        for signal in [SIGFPE, SIGSYS, SIGUSR1] {
            var saved = sigaction()
            _ = realSigaction(signal, nil, &saved)
            savedActions[signal] = saved
        }
        savedExceptionHandler = NSGetUncaughtExceptionHandler()
        throwSiteFile = FileManager.default.temporaryDirectory.appendingPathComponent("throw-site-\(UUID().uuidString).json")

        // The crash reporter's handlers, installed before the takeover:
        var own = action(ownHandler)
        _ = realSigaction(ownedSignal, &own, nil)
        NSSetUncaughtExceptionHandler(ownExceptionHandler)
        ownHandlerCalls = 0
        ownExceptionHandlerCalls = 0
    }

    /// Calls the signal handler really installed, as the system does when the signal is raised.
    private func raiseInstalledHandler(_ signal: Int32) {
        var current = sigaction()
        _ = realSigaction(signal, nil, &current)
        if current.sa_flags & SA_SIGINFO != 0 {
            current.__sigaction_u.__sa_sigaction?(signal, nil, nil)
        } else {
            current.__sigaction_u.__sa_handler?(signal)
        }
    }

    override func tearDown() {
        CrashHandlerTakeover.deactivate()
        for (signal, var saved) in savedActions {
            _ = realSigaction(signal, &saved, nil)
        }
        NSSetUncaughtExceptionHandler(savedExceptionHandler)
        try? FileManager.default.removeItem(at: throwSiteFile)
        super.tearDown()
    }

    // MARK: - Signals

    func testWhenActive_installingAnotherHandlerIsRecordedButNotApplied() {
        // Given
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))

        // When
        var foreign = action(foreignHandler)
        var previous = sigaction()
        let result = sigaction(ownedSignal, &foreign, &previous)

        // Then
        XCTAssertEqual(result, 0)
        XCTAssertEqual(installedHandler(ownedSignal), CrashHandlerTakeover.signalHandler, "The takeover's handler stays installed")
        XCTAssertEqual(address(of: previous), address(of: SIG_DFL), "The caller is not handed the crash reporter's handler")

        var queried = sigaction()
        _ = sigaction(ownedSignal, nil, &queried)
        XCTAssertEqual(address(of: queried), address(of: foreignHandler), "A query sees the handler the caller installed")
    }

    func testWhenActive_resettingToTheDefaultHandlerIsNotApplied() {
        // Given
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
        _ = signal(ownedSignal, foreignHandler)

        // When
        let previous = signal(ownedSignal, SIG_DFL)

        // Then
        XCTAssertEqual(address(of: previous), address(of: foreignHandler))
        XCTAssertEqual(installedHandler(ownedSignal), CrashHandlerTakeover.signalHandler)
    }

    func testWhenActive_theSignalReachesTheCrashReporterHandler() {
        // Given
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))

        // When
        raiseInstalledHandler(ownedSignal)

        // Then
        XCTAssertEqual(ownHandlerCalls, 1)
    }

    func testWhenActive_callsFromThreadsBlockingSignalsAreGuarded() {
        // Given
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
        // Dispatch worker threads run with most signals blocked, SIGABRT included.
        var workerMask = sigset_t()
        sigfillset(&workerMask)
        var previousMask = sigset_t()
        _ = pthread_sigmask(SIG_BLOCK, &workerMask, &previousMask)
        defer { _ = pthread_sigmask(SIG_SETMASK, &previousMask, nil) }

        // When
        _ = signal(ownedSignal, SIG_DFL)

        // Then
        XCTAssertEqual(installedHandler(ownedSignal), CrashHandlerTakeover.signalHandler)
    }

    func testWhenActive_callsFromADispatchQueueAreGuarded() {
        // Given
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))

        // When
        let done = expectation(description: "reset")
        DispatchQueue.global().async {
            _ = signal(self.ownedSignal, SIG_DFL)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        // Then
        XCTAssertEqual(installedHandler(ownedSignal), CrashHandlerTakeover.signalHandler)
    }

    func testWhenActive_signalsItDoesNotOwnAreNotAffected() {
        // Given
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))

        // When
        _ = signal(SIGUSR1, foreignHandler)

        // Then
        XCTAssertEqual(installedHandler(SIGUSR1), address(of: foreignHandler))
    }

    func testWhenACrashIsBeingHandled_handlersCanBeRestored() {
        // Given
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
        raiseInstalledHandler(ownedSignal) // the crash reporter handles a crash

        // When
        var foreign = action(foreignHandler)
        _ = sigaction(ownedSignal, &foreign, nil)

        // Then
        XCTAssertEqual(installedHandler(ownedSignal), address(of: foreignHandler))
    }

    func testWhenACrashIsBeingHandled_theCrashReporterRestoringItsPreviousHandlerInstallsTheRecordedOne() {
        // Given
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
        _ = signal(ownedSignal, SIG_DFL) // another library removes its handler; recorded
        raiseInstalledHandler(ownedSignal) // the crash reporter handles a crash

        // When
        var saved = action(foreignHandler) // the handler the crash reporter saved when it was installed
        _ = sigaction(ownedSignal, &saved, nil)

        // Then
        XCTAssertEqual(installedHandler(ownedSignal), address(of: SIG_DFL), "The handler the other library expects is installed")

        // When (the other library's own calls, once its handler runs)
        var other = action(otherHandler)
        _ = sigaction(ownedSignal, &other, nil)

        // Then
        XCTAssertEqual(installedHandler(ownedSignal), address(of: otherHandler))
    }

    func testWhenACrashIsBeingHandled_handlersWithoutARecordedOneAreRestoredAsRequested() {
        // Given
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
        raiseInstalledHandler(ownedSignal)

        // When
        var saved = action(foreignHandler)
        _ = sigaction(ownedSignal, &saved, nil)

        // Then
        XCTAssertEqual(installedHandler(ownedSignal), address(of: foreignHandler))
    }

    func testWhenTheCrashReporterHandlerIsNoLongerInstalled_callsAreNotAffected() {
        // Given
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
        var other = action(otherHandler)
        _ = realSigaction(ownedSignal, &other, nil) // e.g. replaced through a path the takeover does not see

        // When
        var foreign = action(foreignHandler)
        _ = sigaction(ownedSignal, &foreign, nil)

        // Then
        XCTAssertEqual(installedHandler(ownedSignal), address(of: foreignHandler))
    }

    func testWhenAnImageIsLoaded_itsCallsAreRewritten() throws {
        // Given
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
        var info = Dl_info()
        XCTAssertNotEqual(dladdr(unsafeBitCast(ownHandler as sig_t, to: UnsafeRawPointer.self), &info), 0)
        let testHeader = try XCTUnwrap(info.dli_fbase).assumingMemoryBound(to: mach_header.self)
        let slide = (0..<_dyld_image_count()).first { _dyld_get_image_header($0) == UnsafePointer(testHeader) }
            .map { _dyld_get_image_vmaddr_slide($0) } ?? 0
        // as a newly loaded image, whose calls reach the real `sigaction`:
        SymbolRebinder.rebind([.init(name: "_sigaction", replacement: unsafeBitCast(realSigaction, to: UnsafeRawPointer.self))], inImage: testHeader, slide: slide)

        // When
        rebindAddedImage(testHeader, slide)

        // Then
        var foreign = action(foreignHandler)
        _ = sigaction(ownedSignal, &foreign, nil)
        XCTAssertEqual(installedHandler(ownedSignal), CrashHandlerTakeover.signalHandler)
    }

    func testWhenDeactivated_handlersAreInstalledAgain() {
        // Given
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
        CrashHandlerTakeover.deactivate()
        XCTAssertEqual(installedHandler(ownedSignal), address(of: ownHandler), "The crash reporter's handler is installed again")

        // When
        var foreign = action(foreignHandler)
        _ = sigaction(ownedSignal, &foreign, nil)

        // Then
        XCTAssertEqual(installedHandler(ownedSignal), address(of: foreignHandler))
    }

    func testControl_withoutTheTakeover_anotherHandlerReplacesTheCrashReporters() {
        // When
        var foreign = action(foreignHandler)
        _ = sigaction(ownedSignal, &foreign, nil)

        // Then
        XCTAssertEqual(installedHandler(ownedSignal), address(of: foreignHandler))
    }

    // MARK: - Uncaught Exception Handler

    func testWhenActive_settingAnotherUncaughtExceptionHandlerIsRecordedButNotApplied() {
        // Given
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
        XCTAssertNil(NSGetUncaughtExceptionHandler(), "Before any is recorded, the caller sees no handler")

        // When
        NSSetUncaughtExceptionHandler(foreignExceptionHandler)

        // Then
        XCTAssertEqual(realGetExceptionHandler(), CrashHandlerTakeover.exceptionHandler)
        XCTAssertEqual(
            unsafeBitCast(NSGetUncaughtExceptionHandler(), to: UInt.self),
            unsafeBitCast(foreignExceptionHandler as CExceptionHandler, to: UInt.self)
        )

        // When an exception is not caught
        unsafeBitCast(CrashHandlerTakeover.exceptionHandler, to: CExceptionHandler.self)(NSException(name: .genericException, reason: nil))

        // Then
        XCTAssertEqual(ownExceptionHandlerCalls, 1, "The exception reaches the crash reporter's handler")
    }

    // MARK: - Terminate Handler

    func testWhenActive_itInstallsItsTerminateHandlerAndKeepsIt() throws {
        // Given
        let previousTerminate = realGetTerminate()
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
        let takeoverTerminate = realGetTerminate()
        XCTAssertNotEqual(takeoverTerminate, previousTerminate)

        // When (as another library's `std::set_terminate` call, rewritten to the replacement)
        let replacement = try XCTUnwrap(CrashHandlerTakeover.rebindings.first { $0.name == "__ZSt13set_terminatePFvvE" })
        let setTerminate = unsafeBitCast(replacement.replacement, to: PointerSetter.self)
        _ = setTerminate(unsafeBitCast(foreignTerminate, to: UnsafeMutableRawPointer.self))

        // Then
        XCTAssertEqual(realGetTerminate(), takeoverTerminate)
        let getReplacement = try XCTUnwrap(CrashHandlerTakeover.rebindings.first { $0.name == "__ZSt13get_terminatev" })
        XCTAssertEqual(unsafeBitCast(getReplacement.replacement, to: PointerGetter.self)(), unsafeBitCast(foreignTerminate, to: UnsafeMutableRawPointer.self))

        CrashHandlerTakeover.deactivate()
        XCTAssertEqual(realGetTerminate(), previousTerminate, "Deactivating restores the previous terminate handler")
    }

    // MARK: - Symbol Rebinder

    func testRebinderRewritesImportsOfAppImagesOnly() throws {
        var info = Dl_info()

        // System image:
        XCTAssertNotEqual(dladdr(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "mach_absolute_time"), &info), 0)
        let systemHeader = try XCTUnwrap(info.dli_fbase).assumingMemoryBound(to: mach_header.self)
        XCTAssertTrue(SymbolRebinder.isSystemImage(systemHeader), String(cString: info.dli_fname))

        // This test bundle:
        XCTAssertNotEqual(dladdr(unsafeBitCast(ownHandler as sig_t, to: UnsafeRawPointer.self), &info), 0)
        let testHeader = try XCTUnwrap(info.dli_fbase).assumingMemoryBound(to: mach_header.self)
        XCTAssertFalse(SymbolRebinder.isSystemImage(testHeader))

        // A rebinding applies to this bundle's own calls:
        let fakeGetpid: @convention(c) () -> pid_t = { 4_242 }
        let realGetpid = try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "getpid"))
        let slide = (0..<_dyld_image_count()).first { _dyld_get_image_header($0) == UnsafePointer(testHeader) }
            .map { _dyld_get_image_vmaddr_slide($0) } ?? 0

        XCTAssertGreaterThan(SymbolRebinder.rebind([.init(name: "_getpid", replacement: unsafeBitCast(fakeGetpid, to: UnsafeRawPointer.self))], inImage: testHeader, slide: slide), 0)
        XCTAssertEqual(getpid(), 4_242)
        SymbolRebinder.rebind([.init(name: "_getpid", replacement: UnsafeRawPointer(realGetpid))], inImage: testHeader, slide: slide)
        XCTAssertNotEqual(getpid(), 4_242)

        // and not to a system image:
        XCTAssertEqual(SymbolRebinder.rebind([.init(name: "_getpid", replacement: unsafeBitCast(fakeGetpid, to: UnsafeRawPointer.self))], inImage: systemHeader, slide: 0), 0)
    }
}
