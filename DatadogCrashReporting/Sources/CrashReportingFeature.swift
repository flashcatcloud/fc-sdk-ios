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

    /// Queue for synchronizing internal operations.
    private let queue: DispatchQueue

    let crashContextProvider: CrashContextProvider

    /// An interface for accessing the `DDCrashReportingPlugin` from `DatadogCrashReporting`.
    let plugin: CrashReportingPlugin
    /// Integration enabling sending crash reports as RUM Errors.
    let sender: CrashReportSender
    /// Telemetry interface.
    let telemetry: Telemetry

    init(
        crashReportingPlugin: CrashReportingPlugin,
        crashContextProvider: CrashContextProvider,
        sender: CrashReportSender,
        messageReceiver: FeatureMessageReceiver,
        telemetry: Telemetry
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

        // Inject current `CrashContext`
        if let context = crashContextProvider.currentCrashContext {
            inject(currentCrashContext: context)
        }

        // Register for future `CrashContext` changes
        self.crashContextProvider.onCrashContextChange = { [weak self] in
            self?.inject(currentCrashContext: $0)
        }
    }

    // MARK: - Interaction with `DatadogCrashReporting` plugin

    func sendCrashReportIfFound() {
        queue.async {
            self.plugin.readPendingCrashReports { [weak self] crashReports in
                guard let self = self else {
                    return false
                }

                guard !crashReports.isEmpty else {
                    DD.logger.debug("No pending Crash found")
                    self.sender.send(launch: .init(didCrash: false))
                    return false
                }

                DD.logger.debug("Loaded \(crashReports.count) pending crash report(s)")

                // Each report carries the `CrashContext` of the process that crashed, so each one is sent with its own.
                for crashReport in crashReports {
                    // A report whose `CrashContext` is malformed cannot be processed. It is skipped and purged
                    // along with the others.
                    if let crashContext = crashReport.context.flatMap({ self.decode(crashContextData: $0) }) {
                        self.sender.send(report: crashReport, with: crashContext)
                    }
                }

                self.sender.send(launch: .init(didCrash: true))
                return true
            }
        }
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

    private func inject(currentCrashContext: CrashContext) {
        queue.async {
            if let crashContextData = self.encode(crashContext: currentCrashContext) {
                self.plugin.inject(context: crashContextData)
            }
        }
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
