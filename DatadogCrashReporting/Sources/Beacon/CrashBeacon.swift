/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation
import DatadogInternal

// swiftlint:disable duplicate_imports
#if SPM_BUILD
    #if swift(>=6.0)
    internal import DatadogCrashReportingPrivate
    #else
    @_implementationOnly import DatadogCrashReportingPrivate
    #endif
#endif
// swiftlint:enable duplicate_imports

// FLASHCAT FORK - the crash beacon. See `DDCrashBeacon.h` for how the crashed thread hands over to
// the beacon thread; this file is that thread and what it sends.
//
// The thread is created at startup and blocks on a pipe, so on a crash it only has to build a
// small JSON object from what it already holds and send it. It never reads the crash report: the
// report is written by then, but parsing it is work the crashed thread would be waiting on.
internal final class CrashBeacon {
    /// The crash beacon path, next to the RUM intake.
    static let path = "crash"

    /// The single beacon of this process. A second `CrashReporting.enable()` reuses it.
    private static var installed: CrashBeacon?
    private static let installLock = NSLock()

    /// Installs the signal handler, before KSCrash, and starts the beacon thread.
    ///
    /// Returns `nil` when the beacon is off or cannot be installed (a debugger is attached): the
    /// crash is then reported on the next launch only, as before.
    static func install(crashId: String, enabled: Bool, directory: URL, sender: CrashBeaconRequestSender?) -> CrashBeacon? {
        installLock.lock()
        defer { installLock.unlock() }

        if let installed = installed {
            return installed
        }
        guard enabled, let sender = sender else {
            return nil
        }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let resultURL = CrashBeaconResults(directory: directory).url(forCrashId: crashId)
        let ok = resultURL.path.withCString { path in
            crashId.withCString { id in dd_crash_beacon_install(path, id) }
        }
        guard ok else {
            return nil
        }

        let beacon = CrashBeacon(crashId: crashId, sender: sender)
        beacon.start()
        installed = beacon
        return beacon
    }

    /// Beside the KSCrash reports, in Caches: a result is only useful until its report is sent.
    static var directory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("com.datadoghq.crash-reporting/beacon", isDirectory: true)
    }

    let crashId: String

    private let lock = NSLock()
    private var context: DatadogContext?

    /// The HTTP client of the uploads, so the beacon can reuse their connection and follows the proxy
    /// configured at initialisation. Retained: the core must not go away under a crash.
    private let sender: CrashBeaconRequestSender

    private init(crashId: String, sender: CrashBeaconRequestSender) {
        self.crashId = crashId
        self.sender = sender
    }

    private func start() {
        let thread = Thread { [weak self] in
            let signal = dd_crash_beacon_wait_for_wake()
            guard signal > 0, let self = self else {
                return
            }
            self.send(signal: signal)
        }
        thread.name = "com.flashcat.crash-beacon"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    // MARK: - State

    /// Keeps the context for the beacon thread and hands the current settings to the signal handler,
    /// which reads them without locking.
    func update(context: DatadogContext) {
        lock.lock()
        self.context = context
        lock.unlock()

        let rates = context.additionalContext(ofType: RemoteSamplingRates.self)
        let source = context.additionalContext(ofType: CrashBeaconSource.self)
        let rum = context.additionalContext(ofType: RUMFatalErrorContext.self)
        // Only a crash in a session RUM tracks: the late report is sent for those alone, and a
        // beacon without one would count a crash that never reaches the crash list or the rate.
        let isSessionTracked = rum?.sessionState.map { $0.sessionUUID != .dd.nullUUID } ?? false

        dd_crash_beacon_set_timeout_ms(Int32(rates?.crashBeaconTimeoutMs ?? Self.defaultTimeoutMs))
        dd_crash_beacon_set_foreground(context.applicationStateHistory.currentState.isRunningInForeground)
        dd_crash_beacon_set_armed(
            rates?.crashBeaconEnabled != false
                && context.trackingConsent == .granted
                && source != nil
                && isSessionTracked
        )
    }

    static let defaultTimeoutMs: Int = 1_000

    // MARK: - Sending (beacon thread)

    private func send(signal: Int32) {
        let start = Date()

        lock.lock()
        let context = self.context
        lock.unlock()

        guard let context = context,
              let source = context.additionalContext(ofType: CrashBeaconSource.self),
              let body = try? JSONEncoder().encode(payload(signal: signal, context: context, source: source)) else {
            dd_crash_beacon_finish(DDCrashBeaconResultFailed, 0)
            return
        }

        // Finish a little before the crashed thread stops waiting, so the result is on disk first.
        let timeout = max(0.1, Double(dd_crash_beacon_timeout_ms() - 100) / 1_000)
        var request = URLRequest(url: source.url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let done = DispatchSemaphore(value: 0)
        var result = DDCrashBeaconResultFailed
        sender.sendFromCrashingProcess(request: request) { outcome in
            switch outcome {
            case .success(let response) where (200..<300).contains(response.statusCode):
                result = DDCrashBeaconResultSent
            case .failure(let error as URLError) where error.code == .timedOut:
                result = DDCrashBeaconResultTimeout
            default:
                break
            }
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            result = DDCrashBeaconResultTimeout
        }

        dd_crash_beacon_finish(result, Int32(Date().timeIntervalSince(start) * 1_000))
    }

    internal func payload(signal: Int32, context: DatadogContext, source: CrashBeaconSource) -> Payload {
        let rum = context.additionalContext(ofType: RUMFatalErrorContext.self)
        let lastView = Self.lastViewSeen(in: rum, context: context)
        let now = Date().addingTimeInterval(context.serverTimeOffset)
        let launch = context.launchInfo.processLaunchDate.addingTimeInterval(context.serverTimeOffset)
        let exceptionName = String(cString: dd_crash_beacon_exception_name())
        let exceptionReason = String(cString: dd_crash_beacon_exception_reason())

        return Payload(
            crashId: crashId,
            applicationId: source.applicationID,
            launchTime: launch.timeIntervalSince1970.dd.toInt64Milliseconds,
            date: now.timeIntervalSince1970.dd.toInt64Milliseconds,
            crashType: exceptionName.isEmpty ? Self.signalName(signal) : exceptionName,
            crashMessage: exceptionReason.isEmpty ? nil : String(exceptionReason.prefix(256)),
            sessionId: lastView?.session.id ?? rum?.sessionState?.sessionUUID.uuidString.lowercased(),
            viewId: lastView?.view.id,
            viewUrl: lastView?.view.url,
            viewName: lastView?.view.name,
            usrAnonymousId: context.userInfo?.anonymousId,
            usrId: context.userInfo?.id,
            version: context.version,
            env: context.env,
            service: context.service,
            osName: lastView?.os?.name,
            osVersion: lastView?.os?.version,
            deviceModel: lastView?.device?.model,
            deviceType: lastView?.device?.type?.rawValue,
            sdkVersion: context.sdkVersion,
            source: context.source
        )
    }

    /// The view the late report will link this crash to, by the rule of RUM's `CrashReportReceiver`:
    /// a view that stopped still counts in foreground, as the last screen the user saw, but not in
    /// background.
    private static func lastViewSeen(in rum: RUMFatalErrorContext?, context: DatadogContext) -> RUMViewEvent? {
        guard let view = rum?.view else {
            return nil
        }
        let isStoppedView = view.view.isActive == false
        let isInForeground = context.applicationStateHistory.currentState.isRunningInForeground
        return isStoppedView && !isInForeground ? nil : view
    }

    static func signalName(_ signal: Int32) -> String {
        switch signal {
        case SIGABRT: return "SIGABRT"
        case SIGBUS: return "SIGBUS"
        case SIGFPE: return "SIGFPE"
        case SIGILL: return "SIGILL"
        case SIGPIPE: return "SIGPIPE"
        case SIGSEGV: return "SIGSEGV"
        case SIGSYS: return "SIGSYS"
        case SIGTRAP: return "SIGTRAP"
        default: return "SIGNAL \(signal)"
        }
    }

    /// The body of `POST <intake>/crash`, as the engine reads it.
    internal struct Payload: Encodable, Equatable {
        let crashId: String
        let applicationId: String
        let launchTime: Int64
        let date: Int64
        let crashType: String
        let crashMessage: String?
        let sessionId: String?
        let viewId: String?
        let viewUrl: String?
        let viewName: String?
        let usrAnonymousId: String?
        let usrId: String?
        let version: String
        let env: String
        let service: String
        let osName: String?
        let osVersion: String?
        let deviceModel: String?
        let deviceType: String?
        let sdkVersion: String
        let source: String

        enum CodingKeys: String, CodingKey {
            case crashId = "crash_id"
            case applicationId = "application_id"
            case launchTime = "launch_time"
            case date
            case crashType = "crash_type"
            case crashMessage = "crash_message"
            case sessionId = "session_id"
            case viewId = "view_id"
            case viewUrl = "view_url"
            case viewName = "view_name"
            case usrAnonymousId = "usr_anonymous_id"
            case usrId = "usr_id"
            case version
            case env
            case service
            case osName = "os_name"
            case osVersion = "os_version"
            case deviceModel = "device_model"
            case deviceType = "device_type"
            case sdkVersion = "sdk_version"
            case source
        }
    }
}

extension CrashBeacon: FeatureMessageReceiver {
    func receive(message: FeatureMessage, from core: DatadogCoreProtocol) -> Bool {
        if case .context(let context) = message {
            update(context: context)
        }
        // Never claims a message: the crash context provider handles the same ones.
        return false
    }
}

// MARK: - Results

/// What crashed processes recorded about their beacons, one file per crash id: a crash report can be
/// kept across launches, and another crash can happen in the meantime.
internal struct CrashBeaconResults {
    /// How long a result waits for its report. The intake drops events older than a day.
    static let retention: TimeInterval = 7 * 24 * 60 * 60
    /// How far from the crash a result is written: the beacon wait and a margin.
    static let matchWindow: TimeInterval = 10

    let directory: URL

    func url(forCrashId crashId: String) -> URL {
        directory.appendingPathComponent(crashId)
    }

    /// The result recorded for this crash, left on disk until its report is processed.
    func result(forCrashId crashId: String) -> CrashBeaconResult? {
        guard let data = try? Data(contentsOf: url(forCrashId: crashId)), data.count == Int(DDCrashBeaconRecordSize) else {
            return nil
        }
        let bytes = [UInt8](data)
        let duration = Int64(Int32(bitPattern: UInt32(bytes[1]) | UInt32(bytes[2]) << 8 | UInt32(bytes[3]) << 16 | UInt32(bytes[4]) << 24))

        let status: CrashBeaconResult.Status
        switch bytes[0] {
        case UInt8(DDCrashBeaconResultSent.rawValue): status = .sent
        case UInt8(DDCrashBeaconResultTimeout.rawValue): status = .timeout
        case UInt8(DDCrashBeaconResultFailed.rawValue): status = .failed
        case UInt8(DDCrashBeaconResultSkipped.rawValue): status = .skipped
        default: return nil
        }
        return CrashBeaconResult(status: status, duration: duration)
    }

    func remove(crashId: String) {
        try? FileManager.default.removeItem(at: url(forCrashId: crashId))
    }

    /// The crash id of the result written closest to `date`, for a report that lost its context.
    func crashId(recordedAround date: Date) -> String? {
        files()
            .map { (crashId: $0.url.lastPathComponent, distance: abs($0.modifiedAt.timeIntervalSince(date))) }
            .filter { $0.distance <= Self.matchWindow }
            .min { $0.distance < $1.distance }?
            .crashId
    }

    /// Removes the results no report came for.
    func removeExpired(now: Date = Date()) {
        for file in files() where now.timeIntervalSince(file.modifiedAt) > Self.retention {
            try? FileManager.default.removeItem(at: file.url)
        }
    }

    private func files() -> [(url: URL, modifiedAt: Date)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.compactMap { url in
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).flatMap { $0.map { (url, $0) } }
        }
    }
}
