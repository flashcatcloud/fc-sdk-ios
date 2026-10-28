/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import XCTest
import MachO
import TestUtilities
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
private var foreignExceptionHandlerCalls = 0
private func foreignExceptionHandler(_ exception: NSException) { foreignExceptionHandlerCalls += 1 }
private let foreignTerminate: @convention(c) () -> Void = { abort() }

/// Another library's `sigaction` hook, which rewrote some images only and calls `sigaction` through the imports of its
/// own image (this test bundle). Past a depth of 2 it is in a loop, and stops it.
private var selfCallingHookDepth = 0
private var selfCallingHookLooped = false
private let selfCallingHook: RealSigaction = { signal, action, oldAction in
    selfCallingHookDepth += 1
    defer { selfCallingHookDepth -= 1 }
    guard selfCallingHookDepth <= 2 else {
        selfCallingHookLooped = true
        return realSigaction(signal, action, oldAction)
    }
    return sigaction(signal, action, oldAction)
}

private func address(of handler: sig_t?) -> UInt { unsafeBitCast(handler, to: UInt.self) }
private func address(of action: sigaction) -> UInt { unsafeBitCast(action.__sigaction_u, to: UInt.self) }

private func action(_ handler: sig_t?) -> sigaction {
    var action = sigaction()
    action.__sigaction_u = unsafeBitCast(handler, to: __sigaction_u.self)
    return action
}

/// Points the `sigaction` symbol pointers of every image that point at a hook at the real function again (deactivating
/// the takeover points them all at the function it called through to).
private func unhookSigaction(_ hook: UnsafeRawPointer) {
    let real = SymbolRebinding(name: "_sigaction", replacement: unsafeBitCast(realSigaction, to: UnsafeRawPointer.self))
    for index in 0..<_dyld_image_count() {
        guard let header = _dyld_get_image_header(index) else {
            continue
        }
        var isHooked = false
        SymbolRebinder.symbolPointers(of: [real], inImage: header, slide: _dyld_get_image_vmaddr_slide(index)) { isHooked = isHooked || $1 == hook }
        if isHooked {
            SymbolRebinder.rebind([real], inImage: header, slide: _dyld_get_image_vmaddr_slide(index))
        }
    }
}

/// The handler really installed for a signal, bypassing the takeover.
private func installedHandler(_ signal: Int32) -> UInt {
    var current = sigaction()
    _ = realSigaction(signal, nil, &current)
    return address(of: current)
}

/// A named thread that runs the blocks it is given, one at a time, until stopped.
private final class NamedThread {
    private let start = DispatchSemaphore(value: 0)
    private let finish = DispatchSemaphore(value: 0)
    private var block: (() -> Void)?
    private var isStopped = false
    private(set) var port: thread_t = 0

    init(name: String) {
        let ready = DispatchSemaphore(value: 0)
        Thread {
            pthread_setname_np(name)
            self.port = pthread_mach_thread_np(pthread_self())
            ready.signal()
            while true {
                self.start.wait()
                if self.isStopped {
                    self.finish.signal()
                    return
                }
                self.block?()
                self.finish.signal()
            }
        }.start()
        ready.wait()
    }

    func run(_ block: @escaping () -> Void) {
        self.block = block
        start.signal()
        finish.wait()
    }

    func stop() {
        isStopped = true
        start.signal()
        finish.wait()
    }
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
        foreignExceptionHandlerCalls = 0
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

    /// Under the Thread Sanitizer, a record and a read of the same action that are not synchronized also fail the test.
    func testWhenActive_concurrentRecordsAreSeenWhole() {
        // Given
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
        let signal = ownedSignal
        let writers = 4
        let inconsistent = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        inconsistent.initialize(to: 0)
        defer { inconsistent.deallocate() }

        // When (the handler, mask and flags of each action carry the same number)
        DispatchQueue.concurrentPerform(iterations: writers + 1) { thread in
            for round in 1...5_000 {
                if thread < writers {
                    let value = Int32(thread * 10_000 + round)
                    var recorded = sigaction()
                    recorded.__sigaction_u = unsafeBitCast(UInt(value) << 4, to: __sigaction_u.self)
                    recorded.sa_mask = sigset_t(value)
                    recorded.sa_flags = value
                    _ = sigaction(signal, &recorded, nil)
                } else {
                    var queried = sigaction()
                    _ = sigaction(signal, nil, &queried)
                    let handler = address(of: queried) >> 4
                    if handler != UInt(queried.sa_flags) || queried.sa_mask != sigset_t(queried.sa_flags) {
                        inconsistent.pointee += 1
                    }
                }
            }
        }

        // Then
        XCTAssertEqual(inconsistent.pointee, 0)
        XCTAssertEqual(installedHandler(signal), CrashHandlerTakeover.signalHandler)
    }

    func testWhenAnOlderRecordIsPublishedLast_theNewerOneStaysRecorded() {
        // Given
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
        let older = writeForeignAction(action(foreignHandler), for: ownedSignal)
        let newer = writeForeignAction(action(otherHandler), for: ownedSignal)

        // When (the older record is delayed between writing and publishing)
        publishForeignAction(ticket: newer, for: ownedSignal)
        publishForeignAction(ticket: older, for: ownedSignal)

        // Then
        XCTAssertEqual(recordedForeignAction(for: ownedSignal).map(address(of:)), address(of: otherHandler))
    }

    func testWhenTheSlotOfThePublishedRecordIsRewrittenByANewerOne_theNewerOneIsRead() {
        // Given
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
        let published = writeForeignAction(action(foreignHandler), for: ownedSignal)
        publishForeignAction(ticket: published, for: ownedSignal)

        // When (a full turn of records, not published yet, reuses the published record's slot)
        for _ in 0..<8 {
            _ = writeForeignAction(action(otherHandler), for: ownedSignal)
        }

        // Then
        XCTAssertEqual(recordedForeignAction(for: ownedSignal).map(address(of:)), address(of: otherHandler))
    }

    func testWhenARecordPausedForAFullTurnOfClaimsWritesLast_theNewerPublishedOneStaysRecorded() {
        // Given (a record takes its claim, then pauses before taking its slot)
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
        let pausedClaim = takeForeignActionClaim(for: ownedSignal)

        // When (a full turn of newer records reuses that slot and publishes, then the paused record resumes)
        for _ in 0..<8 {
            publishForeignAction(ticket: writeForeignAction(action(otherHandler), for: ownedSignal), for: ownedSignal)
        }
        let ticket = writeForeignAction(action(foreignHandler), for: ownedSignal, claim: pausedClaim)
        publishForeignAction(ticket: ticket, for: ownedSignal)

        // Then
        XCTAssertEqual(ticket, 0, "The older record is discarded")
        XCTAssertEqual(recordedForeignAction(for: ownedSignal).map(address(of:)), address(of: otherHandler))
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

    func testWhenACrashIsBeingHandled_onlyTheCrashHandlingThreadRestoringAHandlerIsRedirected() {
        // Given
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
        _ = signal(ownedSignal, SIG_DFL) // recorded
        raiseInstalledHandler(ownedSignal) // the crash reporter handles a crash on this thread

        // When (another thread, e.g. a handler the crash was forwarded to on another thread)
        let other = NamedThread(name: "other")
        defer { other.stop() }
        other.run {
            var foreign = action(foreignHandler)
            _ = sigaction(self.ownedSignal, &foreign, nil)
        }

        // Then
        XCTAssertEqual(installedHandler(ownedSignal), address(of: foreignHandler), "Only the crash reporter's restore is redirected")

        // When (the crash reporter restoring its saved handler, on the crash thread)
        var saved = action(otherHandler)
        _ = sigaction(ownedSignal, &saved, nil)

        // Then
        XCTAssertEqual(installedHandler(ownedSignal), address(of: SIG_DFL))
    }

    /// Starts named threads, as the crash reporter does while it is installed. Returns them and their ports.
    private func startThreads(named names: [String]) -> ([NamedThread], [thread_t]) {
        let threads = names.map { NamedThread(name: $0) }
        return (threads, threads.map(\.port))
    }

    func testTheThreadsOfTheTaskIncludeANewThread() {
        let before = CrashHandlerTakeover.taskThreads()
        let thread = NamedThread(name: "New")
        defer { thread.stop() }
        XCTAssertFalse(before.contains(thread.port))
        XCTAssertTrue(CrashHandlerTakeover.taskThreads().contains(thread.port))
    }

    func testWhenActive_theTwoThreadsStartedByTheCrashReporterAreLetThrough() {
        // Given (the crash reporter's Mach exception threads, started while it is installed)
        let (threads, started) = startThreads(named: ["Primary", "Secondary"])
        defer { threads.forEach { $0.stop() } }
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile, threadsStartedByCrashReporter: started, isBeingTraced: { false }))

        // When (the crash reporter restoring handlers while handling a Mach exception)
        threads[1].run {
            var foreign = action(foreignHandler)
            _ = sigaction(self.ownedSignal, &foreign, nil)
        }

        // Then
        XCTAssertEqual(installedHandler(ownedSignal), address(of: foreignHandler))
    }

    func testWhenMoreThreadsWereStarted_theCrashReporterMachThreadsAreFoundByTheirNameInTheBackground() throws {
        // Given
        let (threads, started) = startThreads(
            named: ["KSCrash Exception Handler (Primary)", "Other Exception Handler (Primary)", "KSCrash Exception Handler (Secondary)"]
        )
        defer { threads.forEach { $0.stop() } }

        // When
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile, threadsStartedByCrashReporter: started, isBeingTraced: { false }))
        let deadline = Date(timeIntervalSinceNow: 5)
        while CrashHandlerTakeover.crashReporterMachThreads.isEmpty, Date() < deadline {
            usleep(1_000)
        }

        // Then
        XCTAssertEqual(Set(CrashHandlerTakeover.crashReporterMachThreads), Set([started[0], started[2]]))
        threads[1].run {
            var foreign = action(foreignHandler)
            _ = sigaction(self.ownedSignal, &foreign, nil)
        }
        XCTAssertEqual(installedHandler(ownedSignal), CrashHandlerTakeover.signalHandler, "A thread of another name is guarded")
        threads[0].run {
            var foreign = action(foreignHandler)
            _ = sigaction(self.ownedSignal, &foreign, nil)
        }
        XCTAssertEqual(installedHandler(ownedSignal), address(of: foreignHandler))
    }

    func testWhenTracedByADebugger_noThreadIsTakenForTheCrashReporterMachThreads() {
        // Given
        let (threads, started) = startThreads(named: ["Primary", "Secondary"])
        defer { threads.forEach { $0.stop() } }

        // When
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile, threadsStartedByCrashReporter: started, isBeingTraced: { true }))

        // Then
        XCTAssertEqual(CrashHandlerTakeover.crashReporterMachThreads, [])
    }

    func testWhenTheCrashReporterStartedNoMachThread_activationDoesNotWaitForThem() {
        // When
        let start = Date()
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile, threadsStartedByCrashReporter: [], isBeingTraced: { false }))

        // Then
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1)
        XCTAssertEqual(CrashHandlerTakeover.crashReporterMachThreads, [])
    }

    func testWhenActive_aThreadNamedLikeTheCrashReporterMachThreadsLaterIsGuarded() {
        // Given
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
        let impostor = NamedThread(name: "Other Exception Handler (Primary)")
        defer { impostor.stop() }

        // When
        impostor.run {
            var foreign = action(foreignHandler)
            _ = sigaction(self.ownedSignal, &foreign, nil)
        }

        // Then
        XCTAssertEqual(installedHandler(ownedSignal), CrashHandlerTakeover.signalHandler, "Threads are not recognized by their name")
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

    func testWhenAnotherLibraryRewroteASymbolPointerBefore_theReplacementCallsItsFunction() throws {
        // Given (another library's `sigaction` wrapper, installed in this test image before the takeover)
        var info = Dl_info()
        XCTAssertNotEqual(dladdr(unsafeBitCast(ownHandler as sig_t, to: UnsafeRawPointer.self), &info), 0)
        let testHeader = try XCTUnwrap(info.dli_fbase).assumingMemoryBound(to: mach_header.self)
        let slide = (0..<_dyld_image_count()).first { _dyld_get_image_header($0) == UnsafePointer(testHeader) }
            .map { _dyld_get_image_vmaddr_slide($0) } ?? 0
        let wrapper = unsafeBitCast(SigactionWrapperMock.function, to: UnsafeRawPointer.self)
        SymbolRebinder.rebind([.init(name: "_sigaction", replacement: wrapper)], inImage: testHeader, slide: slide)
        defer {
            CrashHandlerTakeover.deactivate()
            unhookSigaction(wrapper)
        }
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
        SigactionWrapperMock.calls = 0

        // When
        var foreign = action(foreignHandler)
        _ = sigaction(SIGUSR1, &foreign, nil)

        // Then
        XCTAssertEqual(SigactionWrapperMock.calls, 1, "The wrapper still sees the calls the takeover lets through")
        XCTAssertEqual(installedHandler(SIGUSR1), address(of: foreignHandler))

        // When
        _ = sigaction(ownedSignal, &foreign, nil)

        // Then
        XCTAssertEqual(installedHandler(ownedSignal), CrashHandlerTakeover.signalHandler, "Calls about owned signals are still guarded")
    }

    func testWhenAnotherLibraryRewroteOnlySomeImagesAndCallsThroughItsOwnImports_theCallsDoNotLoop() throws {
        // Given (the hook rewrote an image loaded after its own, which the takeover meets first)
        let index = try XCTUnwrap((0..<_dyld_image_count()).first { String(cString: _dyld_get_image_name($0)).hasSuffix("/DatadogInternal.framework/DatadogInternal") })
        let hookedHeader = try XCTUnwrap(_dyld_get_image_header(index))
        let slide = _dyld_get_image_vmaddr_slide(index)
        let hook = unsafeBitCast(selfCallingHook, to: UnsafeRawPointer.self)
        XCTAssertGreaterThan(SymbolRebinder.rebind([.init(name: "_sigaction", replacement: hook)], inImage: hookedHeader, slide: slide), 0)
        defer {
            CrashHandlerTakeover.deactivate()
            unhookSigaction(hook)
        }
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
        selfCallingHookLooped = false

        // When
        var foreign = action(foreignHandler)
        _ = selfCallingHook(SIGUSR1, &foreign, nil)

        // Then
        XCTAssertFalse(selfCallingHookLooped)
        XCTAssertEqual(installedHandler(SIGUSR1), address(of: foreignHandler))
    }

    func testWhenAHandlerIsReplacedByAPathTheTakeoverDoesNotSee_itIsReportedDisplaced() {
        // Given
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
        XCTAssertEqual(CrashHandlerTakeover.displacedHandlers(), [])

        // When
        var other = action(otherHandler)
        _ = realSigaction(ownedSignal, &other, nil)

        // Then
        XCTAssertEqual(CrashHandlerTakeover.displacedHandlers(), ["signal \(ownedSignal)"])
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
        XCTAssertEqual(foreignExceptionHandlerCalls, 1, "Then the handler recorded since")
    }

    func testWhenTheRecordedExceptionHandlerIsTheOneInstalledBeforeTheCrashReporter_itIsNotCalledAgain() {
        // Given (the crash reporter calls the handler installed before it)
        let before = unsafeBitCast(foreignExceptionHandler as CExceptionHandler, to: UnsafeMutableRawPointer.self)
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile, exceptionHandlerBeforeCrashReporter: before))
        NSSetUncaughtExceptionHandler(foreignExceptionHandler) // re-installed by its library

        // When
        unsafeBitCast(CrashHandlerTakeover.exceptionHandler, to: CExceptionHandler.self)(NSException(name: .genericException, reason: nil))

        // Then
        XCTAssertEqual(ownExceptionHandlerCalls, 1)
        XCTAssertEqual(foreignExceptionHandlerCalls, 0)
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

    func testItRecognizesTheSanitizerRuntimes() {
        XCTAssertEqual(CrashHandlerTakeover.sanitizer { $0 == "__asan_init" }, "AddressSanitizer")
        XCTAssertEqual(CrashHandlerTakeover.sanitizer { $0 == "__tsan_init" }, "ThreadSanitizer")
        XCTAssertNil(CrashHandlerTakeover.sanitizer { _ in false })
    }

    func testRebinderGivesRewrittenPagesTheirProtectionBack() throws {
        // Given (a page of `__DATA_CONST` left writable, e.g. by another tool)
        var info = Dl_info()
        XCTAssertNotEqual(dladdr(unsafeBitCast(ownHandler as sig_t, to: UnsafeRawPointer.self), &info), 0)
        let testHeader = try XCTUnwrap(info.dli_fbase).assumingMemoryBound(to: mach_header.self)
        let slide = (0..<_dyld_image_count()).first { _dyld_get_image_header($0) == UnsafePointer(testHeader) }
            .map { _dyld_get_image_vmaddr_slide($0) } ?? 0
        var size: UInt = 0
        let segment = try XCTUnwrap(getsegmentdata(UnsafeRawPointer(testHeader).assumingMemoryBound(to: mach_header_64.self), "__DATA_CONST", &size))
        let address = vm_address_t(UInt(bitPattern: segment))
        XCTAssertEqual(vm_protect(mach_task_self_, address, vm_size_t(size), 0, VM_PROT_READ | VM_PROT_WRITE), KERN_SUCCESS)
        defer { vm_protect(mach_task_self_, address, vm_size_t(size), 0, VM_PROT_READ) }
        // `free` is imported through `__DATA_CONST`; the replacement passes the calls on.
        let realFree = try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "free"))
        let passThroughFree: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
            unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "free"), to: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self)($0)
        }

        // When
        let replacement = unsafeBitCast(passThroughFree, to: UnsafeRawPointer.self)
        XCTAssertGreaterThan(SymbolRebinder.rebind([.init(name: "_free", replacement: replacement)], inImage: testHeader, slide: slide), 0)
        let slots = UnsafeRawPointer(segment).bindMemory(to: UnsafeRawPointer?.self, capacity: Int(size) / MemoryLayout<UnsafeRawPointer>.size)
        let slot = (0..<Int(size) / MemoryLayout<UnsafeRawPointer>.size).first { slots[$0] == replacement }
        SymbolRebinder.rebind([.init(name: "_free", replacement: UnsafeRawPointer(realFree))], inImage: testHeader, slide: slide)
        let slotAddress = vm_address_t(UInt(bitPattern: slots.advanced(by: try XCTUnwrap(slot, "The symbol pointer is in `__DATA_CONST`"))))

        // Then
        XCTAssertEqual(SymbolRebinder.protection(at: slotAddress), VM_PROT_READ | VM_PROT_WRITE)
    }

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
