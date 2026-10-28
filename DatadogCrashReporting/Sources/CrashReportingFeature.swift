/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation
import DatadogInternal

internal final class CrashReportingFeature: DatadogFeature {
    static let name = "crash-reporter"

    let messageReceiver: FeatureMessageReceiver

    /// How long after `start()` the pending crash reports are read. Reading a report formats numbers with `snprintf`,
    /// which takes a libc lock; a crash in the meantime makes the crash handler wait on that lock forever, so the app
    /// hangs and the crash is lost. A crash loop crashes in the first moments of a launch, so reports are read once
    /// that window has passed.
    static let defaultProcessingDelay: TimeInterval = 5

    /// After this many launches in a row that ended before the pending reports were processed, they are read once
    /// without waiting: waiting loses them for good when every launch ends within `processingDelay`. This read still
    /// happens when the process may crash, so in a crash loop a crash during it can, rarely, hang until the system ends
    /// the app: the price of not losing every report of the loop.
    static let maxUnreadLaunches = 2

    /// Queue for synchronizing internal operations.
    private let queue: DispatchQueue

    let crashContextProvider: CrashContextProvider

    /// An interface for accessing the `DDCrashReportingPlugin` from `DatadogCrashReporting`.
    let plugin: CrashReportingPlugin
    /// Integration enabling sending crash reports as RUM Errors.
    let sender: CrashReportSender
    /// Telemetry interface.
    let telemetry: Telemetry
    /// See `defaultProcessingDelay`.
    private let processingDelay: TimeInterval
    /// The app version the bundle declares, as the SDK takes it when no other version is set.
    private let bundleVersion: String?

    /// The current tracking consent. Only accessed from `queue`.
    private var trackingConsent: TrackingConsent?
    /// Whether pending crash reports can be read (`processingDelay` has passed). Only accessed from `queue`.
    private var canReadCrashReports = false

    init(
        crashReportingPlugin: CrashReportingPlugin,
        crashContextProvider: CrashContextProvider,
        sender: CrashReportSender,
        messageReceiver: FeatureMessageReceiver,
        telemetry: Telemetry,
        processingDelay: TimeInterval = CrashReportingFeature.defaultProcessingDelay,
        bundleVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    ) {
        self.queue = DispatchQueue(
            label: "com.datadoghq.crash-reporter",
            target: .global(qos: .utility)
        )
        self.plugin = crashReportingPlugin
        self.sender = sender
        self.crashContextProvider = crashContextProvider
        self.messageReceiver = messageReceiver
        self.telemetry = telemetry
        self.processingDelay = processingDelay
        self.bundleVersion = bundleVersion

        // Inject current `CrashContext`
        if let context = crashContextProvider.currentCrashContext {
            update(currentCrashContext: context)
        }

        // Register for future `CrashContext` changes
        self.crashContextProvider.onCrashContextChange = { [weak self] in
            self?.update(currentCrashContext: $0)
        }
    }

    // MARK: - Interaction with `DatadogCrashReporting` plugin

    /// Tells other features whether the previous process crashed, then sends the pending crash reports once
    /// `processingDelay` has passed. When earlier launches ended before the reports were processed, they are also read
    /// right away, once: what this read cannot process (e.g. as no feature receives crashes yet) is read again once
    /// `processingDelay` has passed.
    func start() {
        queue.async {
            self.sender.send(launch: .init(didCrash: self.plugin.crashedLastLaunch))

            let unreadLaunches = self.plugin.unreadLaunches
            if unreadLaunches >= Self.maxUnreadLaunches {
                self.telemetry.debug(
                    "[CrashReporting] Pending crash reports were not read for \(unreadLaunches) launches",
                    attributes: ["unread_launches": unreadLaunches]
                )
                self.sendPendingCrashReports()
            }
        }
        queue.asyncAfter(deadline: .now() + processingDelay) { [weak self] in
            self?.startReadingCrashReports()
        }
    }

    /// Reads the pending crash reports once `processingDelay` has passed, then whenever consent is resolved. Called on
    /// `queue`.
    private func startReadingCrashReports() {
        guard !canReadCrashReports else {
            return
        }
        canReadCrashReports = true
        sendPendingCrashReports()
    }

    /// Writes the crash context before returning, on the Feature queue (the plugin is always called from it).
    ///
    /// Only for the context known when the Feature is enabled, before it is registered: every later context is
    /// written asynchronously on the Feature queue, after this one.
    func inject(initialCrashContext: CrashContext) {
        queue.sync {
            if let crashContextData = self.encode(crashContext: initialCrashContext) {
                self.plugin.inject(context: crashContextData)
            }
        }
    }

    private func update(currentCrashContext: CrashContext) {
        queue.async {
            if let crashContextData = self.encode(crashContext: currentCrashContext) {
                self.plugin.inject(context: crashContextData)
            }

            // Crashes recorded while consent was pending are kept until it is granted or declined.
            let consent = currentCrashContext.trackingConsent
            let consentIsResolved = consent != self.trackingConsent && consent != .pending
            self.trackingConsent = consent
            if self.canReadCrashReports && consentIsResolved {
                self.sendPendingCrashReports()
            }
        }
    }

    /// Reads the pending crash reports one at a time; each one is deleted only once it is processed. Called on `queue`.
    private func sendPendingCrashReports() {
        plugin.readPendingCrashReports { [weak self] crashReport in
            self?.process(crashReport: crashReport) ?? .kept
        }
    }

    /// Sends the crash report if its consent allows it.
    /// - Returns: what became of the crash report, which decides whether it is deleted.
    private func process(crashReport: DDCrashReport) -> CrashReportOutcome {
        // A report whose `CrashContext` is missing or malformed (e.g. a crash before the first context reached the
        // crash reporter) is still reported, with a context built from the current launch. Kept until one exists.
        guard let crashContext = crashReport.context.flatMap({ self.decode(crashContextData: $0) }) ?? fallbackCrashContext(for: crashReport) else {
            return .kept
        }

        switch (crashContext.trackingConsent, trackingConsent ?? .pending) {
        case (.granted, _), (.pending, .granted):
            // A crash recorded with `.pending` consent is written under the current consent, now `.granted`.
            return sender.send(report: crashReport, with: crashContext)
        case (.notGranted, _), (.pending, .notGranted):
            DD.logger.debug("Deleted a crash report recorded with \(crashContext.trackingConsent) consent")
            return .processed
        case (.pending, .pending):
            // Kept until consent is granted or declined. Pending data does not outlive a launch, so this crash cannot
            // be written as pending data.
            DD.logger.debug("Kept a crash report recorded with pending consent until consent is granted or declined")
            return .kept
        }
    }

    /// The context for a crash report whose own context is missing or malformed: the current launch's context
    /// without anything that belongs to the current process (RUM session, view and attributes, launch date, user
    /// and account), so the crash is not linked to the current session or user. The OS is the crashed process's, from
    /// the report, when it has it, and so are the app version and build when the current version is the bundle's: a
    /// version set otherwise (e.g. by a cross-platform framework, or a custom version) is not the bundle's, so the
    /// report's would not match it. Its consent is `.pending`: it is written under the current consent, never
    /// bypassing it.
    private func fallbackCrashContext(for crashReport: DDCrashReport) -> CrashContext? {
        guard let current = crashContextProvider.currentCrashContext else {
            return nil
        }
        DD.logger.debug("Reporting a crash whose context could not be read, with the current launch's context")
        let system = crashReport.system
        let takesAppVersionOfReport = current.version == bundleVersion
        let os = system?.osVersion.map { version in
            OperatingSystem(
                build: system?.osBuild,
                name: system?.osName ?? current.os.name,
                version: version,
                versionMajor: version.split(separator: ".").first.map(String.init) ?? version
            )
        }
        return CrashContext(
            serverTimeOffset: current.serverTimeOffset,
            service: current.service,
            env: current.env,
            version: takesAppVersionOfReport ? system?.appVersion ?? current.version : current.version,
            buildNumber: takesAppVersionOfReport ? system?.appBuild ?? current.buildNumber : current.buildNumber,
            device: current.device,
            os: os ?? current.os,
            sdkVersion: current.sdkVersion,
            source: current.source,
            trackingConsent: .pending,
            userInfo: nil,
            accountInfo: nil,
            networkConnectionInfo: current.networkConnectionInfo,
            carrierInfo: current.carrierInfo,
            lastIsAppInForeground: current.lastIsAppInForeground,
            appLaunchDate: nil,
            lastRUMViewEvent: nil,
            lastRUMSessionState: nil,
            lastRUMAttributes: nil,
            lastLogAttributes: nil
        )
    }

    // MARK: - CrashContext Encoding and Decoding

    /// JSON encoder used for writing `CrashContext` into JSON `Data` injected to crash report.
    /// Note: this `JSONEncoder` must have the same configuration as the `JSONEncoder` used later for writing payloads to uploadable files.
    /// Otherwise the format of data read and uploaded from crash report context will be different than the format of data retrieved from the user
    /// and written directly to uploadable file.
    internal static let crashContextEncoder: JSONEncoder = .dd.default()
    /// JSON decoder used for reading `CrashContext` from JSON `Data` injected to crash report.
    /// Note: it must follow a configuration that enables reading data encoded with `crashContextEncoder`.
    internal static let crashContextDecoder: JSONDecoder = {
        var decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)
            guard let date = iso8601DateFormatter.date(from: dateString) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date format: Requires ISO8601.")
            }
            return date
        }
        return decoder
    }()

    private func encode(crashContext: CrashContext) -> Data? {
        do {
            return try CrashReportingFeature.crashContextEncoder.encode(crashContext)
        } catch {
            DD.logger.error(
                """
                Failed to encode crash report context. The app state information associated with eventual crash
                report may be not in sync with the current state of the application.
                """,
                error: error
            )

            telemetry.error("Failed to encode crash report context", error: error)
            return nil
        }
    }

    private func decode(crashContextData: Data) -> CrashContext? {
        do {
            return try CrashReportingFeature.crashContextDecoder.decode(CrashContext.self, from: crashContextData)
        } catch {
            DD.logger.error(
                """
                Failed to decode crash report context. The app state information associated with the crash
                report won't be in sync with the state of the application when it crashed.
                """,
                error: error
            )
            telemetry.error("Failed to decode crash report context", error: error)
            return nil
        }
    }
}

extension CrashReportingFeature: Flushable {
    func flush() {
        // Await asynchronous operations completion to safely sink all pending tasks.
        queue.sync {}
    }
}
