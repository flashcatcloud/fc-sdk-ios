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
        let (threads, started) = startThreads(named: ["KSCrash Exception Handler (Primary)", "KSCrash Exception Handler (Secondary)"])
        defer { threads.forEach { $0.stop() } }
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile, threadsStartedByCrashReporter: started, isBeingTraced: { false }))
        let deadline = Date(timeIntervalSinceNow: 5)
        while CrashHandlerTakeover.crashReporterMachThreads.isEmpty, Date() < deadline {
            usleep(1_000)
        }

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

    func testWhenExactlyTwoThreadsOfOtherNamesWereStarted_theyAreNotTakenForTheCrashReporterMachThreads() {
        // Given (the crash reporter started none, e.g. its Mach exception handling is inactive, while the app started two)
        let (threads, started) = startThreads(named: ["App Worker", "Other Exception Handler (Primary)"])
        defer { threads.forEach { $0.stop() } }

        // When
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile, threadsStartedByCrashReporter: started, isBeingTraced: { false }))
        usleep(useconds_t((CrashHandlerTakeover.machThreadsNamingTimeout + 0.5) * 1_000_000))

        // Then
        XCTAssertEqual(CrashHandlerTakeover.crashReporterMachThreads, [])
        threads[0].run {
            var foreign = action(foreignHandler)
            _ = sigaction(self.ownedSignal, &foreign, nil)
        }
        XCTAssertEqual(installedHandler(ownedSignal), CrashHandlerTakeover.signalHandler, "The app thread is guarded")
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
        // Given (two threads that are not the crash reporter's: none would ever be found)
        let (threads, started) = startThreads(named: ["App Worker", "Other Exception Handler (Primary)"])
        defer { threads.forEach { $0.stop() } }

        // When
        let start = Date()
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile, threadsStartedByCrashReporter: started, isBeingTraced: { false }))

        // Then (well under the time the search for them may take, whatever the load of the machine)
        XCTAssertLessThan(Date().timeIntervalSince(start), CrashHandlerTakeover.machThreadsNamingTimeout / 2)
        XCTAssertEqual(CrashHandlerTakeover.crashReporterMachThreads, [])
    }

    func testWhenASearchForTheMachThreadsOutlivesItsActivation_itPublishesNothingForTheNextOne() {
        // Given (a search still running when the takeover is deactivated and activated again)
        let (threads, started) = startThreads(named: ["Unnamed A", "Unnamed B"])
        defer { threads.forEach { $0.stop() } }
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile, threadsStartedByCrashReporter: started, isBeingTraced: { false }))
        CrashHandlerTakeover.deactivate()
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))

        // When (the threads of the first activation are named like the crash reporter's while that search runs)
        threads[0].run { pthread_setname_np("KSCrash Exception Handler (Primary)") }
        threads[1].run { pthread_setname_np("KSCrash Exception Handler (Secondary)") }
        usleep(300_000)

        // Then
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

    func testWhenActive_settingTheUncaughtExceptionHandlerToNilIsRecordedAsNil() {
        // Given
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
        NSSetUncaughtExceptionHandler(foreignExceptionHandler)

        // When (its library removes it)
        NSSetUncaughtExceptionHandler(nil)

        // Then
        XCTAssertEqual(realGetExceptionHandler(), CrashHandlerTakeover.exceptionHandler)
        XCTAssertNil(NSGetUncaughtExceptionHandler())

        // When an exception is not caught
        unsafeBitCast(CrashHandlerTakeover.exceptionHandler, to: CExceptionHandler.self)(NSException(name: .genericException, reason: nil))

        // Then
        XCTAssertEqual(ownExceptionHandlerCalls, 1)
        XCTAssertEqual(foreignExceptionHandlerCalls, 0, "The removed handler is not called")
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

    func testWhenActive_aTerminateHandlerSetToNilIsToldApartFromNoneRecorded() throws {
        // Given
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
        let setReplacement = try XCTUnwrap(CrashHandlerTakeover.rebindings.first { $0.name == "__ZSt13set_terminatePFvvE" })
        let getReplacement = try XCTUnwrap(CrashHandlerTakeover.rebindings.first { $0.name == "__ZSt13get_terminatev" })
        let setTerminate = unsafeBitCast(setReplacement.replacement, to: PointerSetter.self)
        let getTerminate = unsafeBitCast(getReplacement.replacement, to: PointerGetter.self)
        let foreign = unsafeBitCast(foreignTerminate, to: UnsafeMutableRawPointer.self)

        // Then (none recorded: callers see a handler that aborts, as the default one)
        let none = getTerminate()
        XCTAssertNotNil(none)

        // When
        let beforeForeign = setTerminate(foreign)
        let beforeNil = setTerminate(nil)

        // Then
        XCTAssertEqual(beforeForeign, none)
        XCTAssertEqual(beforeNil, foreign)
        XCTAssertNil(getTerminate(), "A recorded `nil` is not mistaken for none recorded")
        XCTAssertNil(setTerminate(foreign), "Setting returns the recorded `nil`")
        CrashHandlerTakeover.deactivate()
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

// MARK: - Edge cases and stress

private typealias RealSetVoid = @convention(c) (UnsafeMutableRawPointer?) -> Void
private typealias ThrowRuntimeError = @convention(c) (UnsafePointer<CChar>?) -> Void

private let realSetTerminate = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_ZSt13set_terminatePFvvE"), to: PointerSetter.self)
private let realSetExceptionHandler = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "NSSetUncaughtExceptionHandler"), to: RealSetVoid.self)
/// `std::__throw_runtime_error(const char *)` of libc++: throws a C++ exception from the C++ runtime.
private let throwRuntimeError = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_ZNSt3__121__throw_runtime_errorEPKc")
    .map { unsafeBitCast($0, to: ThrowRuntimeError.self) }

private var stressMarker = 0
private func eh0(_ exception: NSException) { stressMarker = 100 }
private func eh1(_ exception: NSException) { stressMarker = 101 }
private func eh2(_ exception: NSException) { stressMarker = 102 }
private func eh3(_ exception: NSException) { stressMarker = 103 }
private func sh0(_ signal: Int32) { stressMarker = 200 }
private func sh1(_ signal: Int32) { stressMarker = 201 }
private func sh2(_ signal: Int32) { stressMarker = 202 }

/// Stands for the terminate handler the crash reporter installed before the takeover: it never returns, so the thread
/// that terminated is parked instead of aborting the test process.
private let parkedSemaphore = DispatchSemaphore(value: 0)
private let parkingTerminate: @convention(c) () -> Void = {
    parkedSemaphore.signal()
    while true { sleep(1_000) }
}
private let throwGate = DispatchSemaphore(value: 0)

@inline(never) private func throwFromSiteA() { throwRuntimeError?("a") }
@inline(never) private func throwFromSiteB() { throwRuntimeError?("b") }
@inline(never) private func raiseNSExceptionFromSite() { NSException(name: .genericException, reason: "edge case", userInfo: nil).raise() }

/// Runs a throwing function on a new thread that never catches. `0`: A, `1`: B, `2`: NSException. Waits at the gate first.
private func startThrowingThread(_ kind: Int) {
    var thread: pthread_t?
    let entry: @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? = { argument in
        throwGate.wait()
        switch Int(bitPattern: argument) {
        case 1: throwFromSiteB()
        case 2: raiseNSExceptionFromSite()
        default: throwFromSiteA()
        }
        return nil
    }
    pthread_create(&thread, nil, entry, UnsafeMutableRawPointer(bitPattern: kind))
}

private func symbolName(of address: UInt64) -> String {
    var info = Dl_info()
    guard dladdr(UnsafeRawPointer(bitPattern: UInt(address) - 1), &info) != 0, let name = info.dli_sname else {
        return "?"
    }
    return String(cString: name)
}

private func frames(of throwSite: ThrowSiteRecorder.ThrowSite) -> [[String: Any]] {
    throwSite.addresses.map { address in
        var info = Dl_info()
        var frame: [String: Any] = [:]
        if dladdr(UnsafeRawPointer(bitPattern: UInt(address) - 1), &info) != 0 {
            frame["object_name"] = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? ""
            frame["symbol_name"] = info.dli_sname.map { String(cString: $0) } ?? ""
        }
        return frame
    }
}

extension CrashHandlerTakeoverTests {
    private func testHeaderAndSlide() throws -> (UnsafePointer<mach_header>, Int) {
        var info = Dl_info()
        XCTAssertNotEqual(dladdr(unsafeBitCast(ownHandler as sig_t, to: UnsafeRawPointer.self), &info), 0)
        let testHeader = try XCTUnwrap(info.dli_fbase).assumingMemoryBound(to: mach_header.self)
        let slide = (0..<_dyld_image_count()).first { _dyld_get_image_header($0) == UnsafePointer(testHeader) }
            .map { _dyld_get_image_vmaddr_slide($0) } ?? 0
        return (UnsafePointer(testHeader), slide)
    }

    // MARK: Get-after-set

    func testGetAfterSet_signalHandlersIncludingDefaultIgnoredAndNil() {
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
        let handlers: [(String, sig_t?)] = [("SIG_IGN", SIG_IGN), ("SIG_DFL", SIG_DFL), ("handler", sh0), ("nil", nil), ("SIG_IGN again", SIG_IGN)]
        var expectedPrevious = address(of: SIG_DFL)
        for (name, handler) in handlers {
            let previous = signal(ownedSignal, handler)
            XCTAssertEqual(address(of: previous), expectedPrevious, "signal() returns the previously recorded handler before \(name)")
            var queried = sigaction()
            XCTAssertEqual(sigaction(ownedSignal, nil, &queried), 0)
            XCTAssertEqual(address(of: queried), address(of: handler), "get after set \(name)")
            XCTAssertEqual(installedHandler(ownedSignal), CrashHandlerTakeover.signalHandler)
            expectedPrevious = address(of: handler)
        }
    }

    func testGetAfterSet_sigactionKeepsMaskAndFlags() {
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
        var requested = sigaction()
        requested.__sigaction_u = unsafeBitCast(sh1 as sig_t, to: __sigaction_u.self)
        requested.sa_flags = SA_ONSTACK | SA_NODEFER | SA_RESTART
        sigemptyset(&requested.sa_mask)
        sigaddset(&requested.sa_mask, SIGUSR2)
        sigaddset(&requested.sa_mask, SIGINT)
        XCTAssertEqual(sigaction(ownedSignal, &requested, nil), 0)

        var queried = sigaction()
        _ = sigaction(ownedSignal, nil, &queried)
        XCTAssertEqual(address(of: queried), address(of: sh1))
        XCTAssertEqual(queried.sa_flags, requested.sa_flags)
        XCTAssertEqual(queried.sa_mask, requested.sa_mask)
    }

    func testSigactionWithOldActionAliasingTheNewAction() {
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
        var first = action(sh0)
        _ = sigaction(ownedSignal, &first, nil)

        // The same buffer as the new and the old action, as `sigaction(2)` allows.
        var both = action(sh1)
        let result = withUnsafeMutablePointer(to: &both) { sigaction(ownedSignal, $0, $0) }
        XCTAssertEqual(result, 0)

        XCTAssertEqual(address(of: both), address(of: sh0), "the old action is returned")
        var queried = sigaction()
        _ = sigaction(ownedSignal, nil, &queried)
        XCTAssertEqual(address(of: queried), address(of: sh1), "the new action is the one recorded")
    }

    // MARK: Stress

    func testStress_exceptionHandlerSetAndGetFromManyThreads() {
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
        let handlers: [CExceptionHandler?] = [eh0, eh1, eh2, eh3, nil]
        let valid = Set(handlers.map { unsafeBitCast($0, to: UInt.self) })
        let lock = NSLock()
        var invalid = 0
        var gets = 0
        DispatchQueue.concurrentPerform(iterations: 16) { thread in
            var localInvalid = 0
            var localGets = 0
            for round in 0..<20_000 {
                if (thread + round) % 3 == 0 {
                    NSSetUncaughtExceptionHandler(handlers[(thread * 7 + round) % handlers.count])
                } else {
                    localGets += 1
                    if !valid.contains(unsafeBitCast(NSGetUncaughtExceptionHandler(), to: UInt.self)) {
                        localInvalid += 1
                    }
                }
            }
            lock.lock()
            invalid += localInvalid
            gets += localGets
            lock.unlock()
        }
        XCTAssertEqual(invalid, 0, "of \(gets) gets")
        XCTAssertEqual(realGetExceptionHandler(), CrashHandlerTakeover.exceptionHandler, "the takeover's handler stays installed")
        NSSetUncaughtExceptionHandler(eh2)
        XCTAssertEqual(unsafeBitCast(NSGetUncaughtExceptionHandler(), to: UInt.self), unsafeBitCast(eh2 as CExceptionHandler, to: UInt.self), "get after set, once quiet")
    }

    func testStress_terminateSetAndGetFromManyThreads() throws {
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
        let set = unsafeBitCast(try XCTUnwrap(CrashHandlerTakeover.rebindings.first { $0.name == "__ZSt13set_terminatePFvvE" }).replacement, to: PointerSetter.self)
        let get = unsafeBitCast(try XCTUnwrap(CrashHandlerTakeover.rebindings.first { $0.name == "__ZSt13get_terminatev" }).replacement, to: PointerGetter.self)
        let takeoverTerminate = realGetTerminate()
        let a = unsafeBitCast(foreignTerminate, to: UnsafeMutableRawPointer.self)
        let b = unsafeBitCast(parkingTerminate, to: UnsafeMutableRawPointer.self)
        let none = get() // what callers see when nothing was recorded
        let lock = NSLock()
        var invalid = 0
        DispatchQueue.concurrentPerform(iterations: 16) { thread in
            var localInvalid = 0
            for round in 0..<20_000 {
                switch (thread + round) % 4 {
                case 0: _ = set(a)
                case 1: _ = set(b)
                case 2: _ = set(nil)
                default:
                    let current = get()
                    if current != a, current != b, current != nil, current != none { localInvalid += 1 }
                }
            }
            lock.lock()
            invalid += localInvalid
            lock.unlock()
        }
        XCTAssertEqual(invalid, 0)
        XCTAssertEqual(realGetTerminate(), takeoverTerminate)
        _ = set(a)
        XCTAssertEqual(get(), a)
    }

    func testStress_signalAndSigactionFromManyThreadsIncludingDefaultIgnoredAndNil() {
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
        let handlers: [sig_t?] = [SIG_DFL, SIG_IGN, sh0, sh1, sh2, nil]
        let valid = Set(handlers.map { address(of: $0) })
        let lock = NSLock()
        var invalid = 0
        let signalNumber = ownedSignal
        DispatchQueue.concurrentPerform(iterations: 16) { thread in
            var localInvalid = 0
            for round in 0..<20_000 {
                let handler = handlers[(thread * 5 + round) % handlers.count]
                switch (thread + round) % 4 {
                case 0:
                    let previous = signal(signalNumber, handler)
                    if !valid.contains(address(of: previous)) { localInvalid += 1 }
                case 1:
                    var new = action(handler)
                    var old = sigaction()
                    _ = sigaction(signalNumber, &new, &old)
                    if !valid.contains(address(of: old)) { localInvalid += 1 }
                default:
                    var old = sigaction()
                    _ = sigaction(signalNumber, nil, &old)
                    if !valid.contains(address(of: old)) { localInvalid += 1 }
                }
            }
            lock.lock()
            invalid += localInvalid
            lock.unlock()
        }
        XCTAssertEqual(invalid, 0)
        XCTAssertEqual(installedHandler(signalNumber), CrashHandlerTakeover.signalHandler)
        raiseInstalledHandler(signalNumber)
        XCTAssertEqual(ownHandlerCalls, 1, "the crash reporter's handler still receives the signal")
    }

    // MARK: Activation cycles

    func testActivateDeactivateActivateCyclesKeepTheChainFlat() {
        let terminateBefore = realGetTerminate()
        for cycle in 0..<100 {
            XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile), "cycle \(cycle)")
            XCTAssertEqual(installedHandler(ownedSignal), CrashHandlerTakeover.signalHandler)
            XCTAssertEqual(realGetExceptionHandler(), CrashHandlerTakeover.exceptionHandler)
            var foreign = action(foreignHandler)
            _ = sigaction(ownedSignal, &foreign, nil)
            NSSetUncaughtExceptionHandler(foreignExceptionHandler)
            XCTAssertEqual(CrashHandlerTakeover.displacedHandlers(), [])

            CrashHandlerTakeover.deactivate()
            XCTAssertEqual(installedHandler(ownedSignal), address(of: ownHandler), "cycle \(cycle): the crash reporter's handler is back")
            XCTAssertEqual(realGetTerminate(), terminateBefore, "cycle \(cycle)")
            XCTAssertEqual(unsafeBitCast(realGetExceptionHandler(), to: UInt.self), unsafeBitCast(ownExceptionHandler as CExceptionHandler, to: UInt.self))
        }

        // The cycles left no recorded handler or nesting behind.
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
        var queried = sigaction()
        _ = sigaction(ownedSignal, nil, &queried)
        XCTAssertEqual(address(of: queried), address(of: SIG_DFL), "a record of an earlier activation is not seen")
        XCTAssertNil(NSGetUncaughtExceptionHandler())
        raiseInstalledHandler(ownedSignal)
        XCTAssertEqual(ownHandlerCalls, 1)
        unsafeBitCast(CrashHandlerTakeover.exceptionHandler, to: CExceptionHandler.self)(NSException(name: .genericException, reason: nil))
        XCTAssertEqual(ownExceptionHandlerCalls, 1)
        XCTAssertEqual(foreignExceptionHandlerCalls, 0)
    }

    func testDeactivateLeavesATerminateHandlerInstalledThroughAnUnguardedPath() {
        // Given
        let previous = realGetTerminate()
        defer { _ = realSetTerminate(previous) }
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
        let other = unsafeBitCast(foreignTerminate, to: UnsafeMutableRawPointer.self)
        _ = realSetTerminate(other) // e.g. a system framework: not rewritten, so not guarded

        // When
        CrashHandlerTakeover.deactivate()

        // Then
        XCTAssertEqual(realGetTerminate(), other, "a handler that replaced the takeover's is not replaced again")
    }

    func testControl_deactivateLeavesAHandlerInstalledThroughAnUnguardedPath() {
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
        var other = action(otherHandler)
        _ = realSigaction(ownedSignal, &other, nil)
        realSetExceptionHandler(unsafeBitCast(eh1 as CExceptionHandler, to: UnsafeMutableRawPointer.self))

        CrashHandlerTakeover.deactivate()

        XCTAssertEqual(installedHandler(ownedSignal), address(of: otherHandler))
        XCTAssertEqual(unsafeBitCast(realGetExceptionHandler(), to: UInt.self), unsafeBitCast(eh1 as CExceptionHandler, to: UInt.self))
    }

    // MARK: Crash in progress

    func testWhileACrashIsBeingHandled_everyOwnedSignalIsRedirectedOnceOnTheCrashThread() {
        var own = action(ownHandler)
        _ = realSigaction(SIGSYS, &own, nil)
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
        _ = signal(ownedSignal, foreignHandler) // recorded
        _ = signal(SIGSYS, otherHandler) // recorded
        raiseInstalledHandler(ownedSignal)

        var saved = action(sh2)
        _ = sigaction(SIGSYS, &saved, nil)
        _ = sigaction(ownedSignal, &saved, nil)

        XCTAssertEqual(installedHandler(SIGSYS), address(of: otherHandler))
        XCTAssertEqual(installedHandler(ownedSignal), address(of: foreignHandler))

        _ = sigaction(SIGSYS, &saved, nil) // the second install is not redirected
        XCTAssertEqual(installedHandler(SIGSYS), address(of: sh2))
    }

    func testTwoThreadsReachingTheCrashReporterAtOnce_onlyOneIsTheCrashThread() {
        var own = action(ownHandler)
        _ = realSigaction(SIGSYS, &own, nil)
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
        _ = signal(ownedSignal, foreignHandler)
        _ = signal(SIGSYS, otherHandler)
        let first = NamedThread(name: "crash 1")
        let second = NamedThread(name: "crash 2")
        defer { first.stop(); second.stop() }
        first.run { self.raiseInstalledHandler(self.ownedSignal) } // the first to reach the crash reporter

        second.run { self.raiseInstalledHandler(SIGSYS) }
        var saved = action(sh2)
        var redirectedOnSecond = false
        second.run {
            _ = sigaction(SIGSYS, &saved, nil)
            redirectedOnSecond = installedHandler(SIGSYS) == address(of: otherHandler)
        }
        XCTAssertFalse(redirectedOnSecond, "only the first thread that reached the handlers is the crash thread")
        XCTAssertEqual(installedHandler(SIGSYS), address(of: sh2))
        first.run { _ = sigaction(self.ownedSignal, &saved, nil) }
        XCTAssertEqual(installedHandler(ownedSignal), address(of: foreignHandler))
    }

    // MARK: Images

    // MARK: C++ exceptions through terminate

    private func withParkingTerminate(_ body: () throws -> Void) rethrows {
        let previous = realSetTerminate(unsafeBitCast(parkingTerminate, to: UnsafeMutableRawPointer.self))
        defer {
            CrashHandlerTakeover.deactivate()
            _ = realSetTerminate(previous)
        }
        try body()
    }

    func testAnUncaughtCppExceptionRecordsItsThrowSiteOnce_belowTheRuntimeFrames() throws {
        try XCTSkipIf(throwRuntimeError == nil)
        try withParkingTerminate {
            XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
            XCTAssertNil(ThrowSiteRecorder.read(from: throwSiteFile))

            startThrowingThread(0)
            throwGate.signal()
            XCTAssertEqual(parkedSemaphore.wait(timeout: .now() + 5), .success, "the crash reporter's terminate handler is called")

            let throwSite = try XCTUnwrap(ThrowSiteRecorder.read(from: throwSiteFile))
            XCTAssertEqual(throwSite.processID, Int64(getpid()))
            let frames = frames(of: throwSite)
            let index = ThrowSiteRecorder.throwSiteIndex(in: frames)
            let names = frames.map { ($0["object_name"] as? String ?? "?") + ":" + ($0["symbol_name"] as? String ?? "?") }
            XCTAssertGreaterThan(index, 0, "\(names)")
            XCTAssertTrue(names.indices.contains(index) && names[index].contains("throwFromSiteA"), "the throw site is the throwing function: \(names)")
        }
    }

    func testASecondTerminatingThreadDoesNotOverwriteTheRecordedThrowSite() throws {
        try XCTSkipIf(throwRuntimeError == nil)
        try withParkingTerminate {
            XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
            startThrowingThread(1)
            throwGate.signal()
            XCTAssertEqual(parkedSemaphore.wait(timeout: .now() + 5), .success)
            let recorded = try Data(contentsOf: throwSiteFile)
            usleep(20_000) // the clock moves on, so an overwrite would show

            startThrowingThread(0)
            startThrowingThread(2) // and an Objective-C exception
            throwGate.signal()
            throwGate.signal()
            XCTAssertEqual(parkedSemaphore.wait(timeout: .now() + 5), .success, "the second thread still reaches the crash reporter")
            XCTAssertEqual(parkedSemaphore.wait(timeout: .now() + 5), .success, "and the third")

            XCTAssertEqual(try Data(contentsOf: throwSiteFile), recorded)
            let names = frames(of: try XCTUnwrap(ThrowSiteRecorder.read(from: throwSiteFile))).compactMap { $0["symbol_name"] as? String }
            XCTAssertTrue(names.contains { $0.contains("throwFromSiteB") })
            XCTAssertFalse(names.contains { $0.contains("throwFromSiteA") })
        }
    }

    func testAnUncaughtNSExceptionRecordsNoThrowSite() throws {
        try withParkingTerminate {
            XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
            startThrowingThread(2)
            throwGate.signal()
            XCTAssertEqual(parkedSemaphore.wait(timeout: .now() + 5), .success)
            XCTAssertNil(ThrowSiteRecorder.read(from: throwSiteFile))
        }
    }

    func testStress_twoThreadsTerminatingAtOnceRecordOneWholeThrowSite() throws {
        try XCTSkipIf(throwRuntimeError == nil)
        try withParkingTerminate {
            var mixed = 0
            var unreadable = 0
            let rounds = 40
            for round in 0..<rounds {
                try? FileManager.default.removeItem(at: throwSiteFile)
                XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile), "round \(round)")
                startThrowingThread(0)
                startThrowingThread(1)
                throwGate.signal()
                throwGate.signal()
                XCTAssertEqual(parkedSemaphore.wait(timeout: .now() + 5), .success)
                XCTAssertEqual(parkedSemaphore.wait(timeout: .now() + 5), .success)
                guard let throwSite = ThrowSiteRecorder.read(from: throwSiteFile) else {
                    unreadable += 1
                    continue
                }
                let names = frames(of: throwSite).compactMap { $0["symbol_name"] as? String }
                let hasA = names.contains { $0.contains("throwFromSiteA") }
                let hasB = names.contains { $0.contains("throwFromSiteB") }
                if hasA == hasB { mixed += 1 }
                CrashHandlerTakeover.deactivate()
            }
            XCTAssertEqual(unreadable, 0, "of \(rounds) rounds")
            XCTAssertEqual(mixed, 0, "of \(rounds) rounds")
        }
    }
}

// MARK: - Type names, reordered activation, second crashing thread

private let faultSemaphore = DispatchSemaphore(value: 0)
/// Stands in for the crash reporter when the code under test faults: records the fault and parks the faulting thread.
private let faultHandler: @convention(c) (Int32, UnsafeMutablePointer<__siginfo>?, UnsafeMutableRawPointer?) -> Void = { _, _, _ in
    faultSemaphore.signal()
    while true { sleep(1_000) }
}

/// Runs a block on a thread of its own with SIGSEGV and SIGBUS caught: the thread is parked on a fault, so a fault
/// fails a test instead of ending the test process. Returns `(completed, faulted)`.
private func runCatchingFaults(timeout: TimeInterval = 5, _ body: @escaping () -> Void) -> (completed: Bool, faulted: Bool) {
    var saved: [Int32: sigaction] = [:]
    var handler = sigaction()
    handler.__sigaction_u.__sa_sigaction = faultHandler
    handler.sa_flags = SA_SIGINFO
    for signal in [SIGSEGV, SIGBUS] {
        var old = sigaction()
        _ = realSigaction(signal, &handler, &old)
        saved[signal] = old
    }
    defer {
        for (signal, var old) in saved { _ = realSigaction(signal, &old, nil) }
    }
    while faultSemaphore.wait(timeout: .now()) == .success {}
    let done = DispatchSemaphore(value: 0)
    Thread { body(); done.signal() }.start()
    let deadline = Date(timeIntervalSinceNow: timeout)
    while Date() < deadline {
        if done.wait(timeout: .now() + 0.01) == .success { return (true, false) }
        if faultSemaphore.wait(timeout: .now()) == .success { return (false, true) }
    }
    return (false, false)
}

private final class EdgeException: NSException {}
private typealias ObjCThrow = @convention(c) (AnyObject?) -> Void
private let objcExceptionThrow = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_exception_throw").map { unsafeBitCast($0, to: ObjCThrow.self) }

extension CrashHandlerTakeoverTests {
    // MARK: Type names

    /// On arm64 the C++ runtime sets the high bit of the type name pointer of a type that may be defined in several images
    /// (a class with vague linkage, e.g. an app's own exception class), and `std::type_info::name()` clears it.
    func testShouldRecordReadsTheNameOfATypeWhoseNamePointerHasTheNonUniqueBitSet() throws {
        #if arch(arm64)
        let name = try XCTUnwrap(strdup("9PlainError"))
        defer { free(name) }
        let typeInfo = UnsafeMutablePointer<UInt>.allocate(capacity: 2)
        defer { typeInfo.deallocate() }
        typeInfo[0] = 0
        typeInfo[1] = UInt(bitPattern: name) | (1 << 63)
        var recorded: Bool?
        let outcome = runCatchingFaults { recorded = ThrowSiteRecorder.shouldRecord(exceptionType: UnsafeRawPointer(typeInfo)) }
        XCTAssertFalse(outcome.faulted, "reading the type name faults on the non-unique bit")
        XCTAssertTrue(outcome.completed)
        XCTAssertEqual(recorded, true)
        #else
        throw XCTSkip("arm64 only")
        #endif
    }

    func testControl_shouldRecordReadsTheNameOfATypeWithAPlainNamePointer() {
        var recorded: Bool?
        let outcome = runCatchingFaults {
            "9PlainError".withCString { name in
                var typeInfo: (UnsafeRawPointer?, UnsafePointer<CChar>?) = (nil, name)
                recorded = withUnsafeBytes(of: &typeInfo) { ThrowSiteRecorder.shouldRecord(exceptionType: $0.baseAddress!) }
            }
        }
        XCTAssertTrue(outcome.completed)
        XCTAssertEqual(recorded, true)
    }

    // MARK: Objective-C exceptions through terminate

    func testAnUncaughtNSExceptionSubclassReachesTheCrashReporter() throws {
        try withParkingTerminate {
            XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
            let outcome = runCatchingFaults(timeout: 3) { EdgeException(name: .genericException, reason: "subclass", userInfo: nil).raise() }
            XCTAssertFalse(outcome.faulted)
            XCTAssertEqual(parkedSemaphore.wait(timeout: .now() + 2), .success)
        }
    }

    func testAnUncaughtObjectiveCObjectThatIsNoNSExceptionReachesTheCrashReporter() throws {
        let throwObject = try XCTUnwrap(objcExceptionThrow)
        try withParkingTerminate {
            XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
            let outcome = runCatchingFaults(timeout: 3) { throwObject("not an exception" as NSString) }
            XCTAssertFalse(outcome.faulted)
            XCTAssertEqual(parkedSemaphore.wait(timeout: .now() + 2), .success)
        }
    }

    // MARK: Second crashing thread

    func testWhenASecondCrashingThreadRestoresFirst_theCrashThreadIsStillRedirectedOnce() {
        var own = action(ownHandler)
        _ = realSigaction(SIGSYS, &own, nil)
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
        _ = signal(SIGSYS, otherHandler) // recorded
        let first = NamedThread(name: "crash A")
        let second = NamedThread(name: "crash B")
        defer { first.stop(); second.stop() }
        first.run { self.raiseInstalledHandler(SIGSYS) } // the crash thread
        second.run { self.raiseInstalledHandler(SIGSYS) } // a second crash
        var saved = action(sh2)

        second.run { _ = sigaction(SIGSYS, &saved, nil) } // the crash reporter's uninstall, on the second thread
        XCTAssertEqual(installedHandler(SIGSYS), address(of: sh2), "not redirected: it is not the crash thread")
        var savedByCrashReporter = action(sh1)
        first.run { _ = sigaction(SIGSYS, &savedByCrashReporter, nil) }
        XCTAssertEqual(installedHandler(SIGSYS), address(of: otherHandler), "the redirection was not used up by the second thread")
    }

    func testWhenTheCrashThreadAndAMachThreadRestore_onlyTheFirstIsRedirected() {
        var own = action(ownHandler)
        _ = realSigaction(SIGSYS, &own, nil)
        let machThread = NamedThread(name: "KSCrash Exception Handler (Primary)")
        let otherMachThread = NamedThread(name: "KSCrash Exception Handler (Secondary)")
        defer { machThread.stop(); otherMachThread.stop() }
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile, threadsStartedByCrashReporter: [machThread.port, otherMachThread.port]))
        _ = signal(SIGSYS, otherHandler)
        usleep(100_000) // the threads are named and found in the background
        var saved = action(sh2)
        machThread.run { _ = sigaction(SIGSYS, &saved, nil) }
        XCTAssertEqual(installedHandler(SIGSYS), address(of: otherHandler))
        var again = action(sh1)
        otherMachThread.run { _ = sigaction(SIGSYS, &again, nil) }
        XCTAssertEqual(installedHandler(SIGSYS), address(of: sh1), "a second restore is applied as requested")
    }

    // MARK: Reordered activation

    func testWhenTwoImagesWereRewrittenByTheSameLibrary_theWrapperSeesEachLetThroughCallOnce() throws {
        // Given
        let (testHeader, testSlide) = try testHeaderAndSlide()
        let index = try XCTUnwrap((0..<_dyld_image_count()).first { String(cString: _dyld_get_image_name($0)).hasSuffix("/DatadogInternal.framework/DatadogInternal") })
        let internalHeader = try XCTUnwrap(_dyld_get_image_header(index))
        let wrapper = unsafeBitCast(SigactionWrapperMock.function, to: UnsafeRawPointer.self)
        let rewriting = [SymbolRebinding(name: "_sigaction", replacement: wrapper)]
        SymbolRebinder.rebind(rewriting, inImage: testHeader, slide: testSlide)
        SymbolRebinder.rebind(rewriting, inImage: internalHeader, slide: _dyld_get_image_vmaddr_slide(index))
        defer {
            CrashHandlerTakeover.deactivate()
            unhookSigaction(wrapper)
        }
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
        SigactionWrapperMock.calls = 0

        // When (the callback replays every image, twice)
        for _ in 0..<2 {
            for imageIndex in 0..<_dyld_image_count() {
                if let header = _dyld_get_image_header(imageIndex) { rebindAddedImage(header, _dyld_get_image_vmaddr_slide(imageIndex)) }
            }
        }
        var foreign = action(foreignHandler)
        _ = sigaction(SIGUSR1, &foreign, nil)

        // Then
        XCTAssertEqual(SigactionWrapperMock.calls, 1, "the wrapper is called once, not once per rewritten image or per replay")
        XCTAssertEqual(installedHandler(SIGUSR1), address(of: foreignHandler))
        _ = sigaction(ownedSignal, &foreign, nil)
        XCTAssertEqual(installedHandler(ownedSignal), CrashHandlerTakeover.signalHandler)
    }

    func testTheUncaughtExceptionHandlerPassesOnAnObjectThatIsNoNSException() {
        XCTAssertTrue(CrashHandlerTakeover.activate(throwSiteFile: throwSiteFile))
        NSSetUncaughtExceptionHandler(foreignExceptionHandler) // recorded
        let handler = unsafeBitCast(CrashHandlerTakeover.exceptionHandler, to: (@convention(c) (AnyObject) -> Void).self)
        handler("not an exception" as NSString)
        XCTAssertEqual(ownExceptionHandlerCalls, 1)
        XCTAssertEqual(foreignExceptionHandlerCalls, 1)
    }
}
