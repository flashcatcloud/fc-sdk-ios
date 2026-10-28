/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation
import DatadogInternal

/// Receiver to consume crash reports as RUM events.
internal struct CrashReportReceiver: FeatureMessageReceiver {
    private struct AdjustedCrashTimings {
        /// Crash date read from `CrashReport`. It uses device time.
        let crashDate: Date
        /// Crash date adjusted with current time correction. It uses NTP time.
        let realCrashDate: Date
        /// Current time, adjusted with NTP correction.
        let realDateNow: Date
        /// Time between crash and application launch
        let timeSinceAppStart: TimeInterval?
    }

    /// RUM feature scope.
    let featureScope: FeatureScope
    let applicationID: String
    let dateProvider: DateProvider
    let sessionSampler: Sampler
    /// FLASHCAT FORK - the console's rates as they stand right now; always nil when the
    /// application did not opt in to remote configuration.
    let remoteSamplingRates: () -> RemoteSamplingRates?
    let uuidGenerator: RUMUUIDGenerator
    /// Integration with CIApp tests. It contains the CIApp test context when active.
    let ciTest: RUMCITest?
    /// Integration with Synthetics tests. It contains the Synthetics test context when active.
    let syntheticsTest: RUMSyntheticsTest?
    let eventsMapper: RUMEventsMapper

    /// FLASHCAT FORK - the rate a session invented for a crash is drawn at, and reported with.
    ///
    /// The console's value where it published one, the value the app was initialised with
    /// otherwise — the same order every other draw uses. Without it the kill switch would not hold
    /// on this one path: an operator setting the rate to zero to stop collection would still get
    /// crashes from the sessions invented here, drawn and reported at a rate the console had
    /// already replaced.
    ///
    /// It takes the console's rates as an argument rather than reading them, because the draw and
    /// the report are two separate moments and the rates can change between them. Read twice, this
    /// SDK could report a rate that did not decide the very crash it is reporting on — which is the
    /// one thing the reported rate is for. One crash reads them once; see `send(report:with:)`.
    ///
    /// It only reaches the crash that arrives with no session of its own to speak for it. A crash
    /// belonging to a session that really ran reports what THAT session was drawn with, which is
    /// carried on its stored state and is the better answer wherever it exists.
    private func drawnSessionSampleRate(under remoteRates: RemoteSamplingRates?) -> SampleRate {
        remoteRates?.sessionSampleRate ?? sessionSampler.samplingRate
    }

    // MARK: - Initialization

    init(
        featureScope: FeatureScope,
        applicationID: String,
        dateProvider: DateProvider,
        sessionSampler: Sampler,
        remoteSamplingRates: @escaping () -> RemoteSamplingRates? = { nil },
        uuidGenerator: RUMUUIDGenerator,
        ciTest: RUMCITest?,
        syntheticsTest: RUMSyntheticsTest?,
        eventsMapper: RUMEventsMapper
    ) {
        self.featureScope = featureScope
        self.applicationID = applicationID
        self.dateProvider = dateProvider
        self.sessionSampler = sessionSampler
        self.remoteSamplingRates = remoteSamplingRates
        self.uuidGenerator = uuidGenerator
        self.ciTest = ciTest
        self.syntheticsTest = syntheticsTest
        self.eventsMapper = eventsMapper
    }

    func receive(message: FeatureMessage, from core: DatadogCoreProtocol) -> Bool {
        guard case let .payload(crash as Crash) = message else {
            return false
        }

        return send(report: crash.report, with: crash.context, completion: crash.completion)
    }

    /// - Parameter completion: called once the crash events are written, or once it is decided not to write any.
    /// - Returns: always `true` for a crash: declining it on purpose is a decision, and the sender keeps a crash only
    ///   when no receiver handles it at all.
    private func send(report: DDCrashReport, with context: CrashContext, completion: @escaping (CrashReportOutcome) -> Void) -> Bool {
        // The `crashReport.crashDate` uses system `Date` collected at the moment of crash, so we need to adjust it
        // to the server time before processing. Following use of the current correction is not ideal (it's not the correction
        // from the moment of crash), but this is the best approximation we can get.
        let currentTimeCorrection = context.serverTimeOffset

        let crashDate = report.date ?? dateProvider.now
        var timeSinceAppStart: TimeInterval? = nil
        if let startDate = context.appLaunchDate {
            timeSinceAppStart = crashDate.timeIntervalSince(startDate)
        }

        let adjustedCrashTimings = AdjustedCrashTimings(
            crashDate: crashDate,
            realCrashDate: crashDate.addingTimeInterval(currentTimeCorrection),
            realDateNow: dateProvider.now.addingTimeInterval(currentTimeCorrection),
            timeSinceAppStart: timeSinceAppStart
        )

        // FLASHCAT FORK - read once, for this whole crash. The controller updates these on its own
        // queue whenever the console answers, so reading them again further down could draw with
        // one rate and report another.
        let remoteRates = remoteSamplingRates()

        // RUMM-2516 if a cross-platform crash was reported, do not send its native version
        if var lastRUMViewEvent = lastViewSeen(in: context) {
            if let lastRUMAttributes = context.lastRUMAttributes {
                // RUM-3588: If last RUM attributes are available, use them to replace view attributes as we know that
                // global RUM attributes can be updated more often than attributes in `lastRUMView`.
                // See https://github.com/DataDog/dd-sdk-ios/pull/1834 for more context.
                lastRUMViewEvent.context = lastRUMAttributes
            }
            if lastRUMViewEvent.view.crash?.count ?? 0 < 1 {
                sendCrashReportLinkedToLastViewInPreviousSession(
                    report,
                    lastRUMViewEventInPreviousSession: lastRUMViewEvent,
                    using: adjustedCrashTimings,
                    bypassConsent: canBypassConsent(context),
                    completion: completion
                )
            } else {
                DD.logger.debug("There was a crash in previous session, but it is ignored due to another crash already present in the last view.")
                completion(.processed)
            }
        } else if let lastRUMSessionState = context.lastRUMSessionState {
            sendCrashReportToPreviousSession(
                report,
                crashContext: context,
                lastRUMSessionStateInPreviousSession: lastRUMSessionState,
                using: adjustedCrashTimings,
                under: remoteRates,
                completion: completion
            )
        } else if Sampler(samplingRate: drawnSessionSampleRate(under: remoteRates)).sample() { // before producing a new RUM session, we must consider sampling
            sendCrashReportToNewSession(report, crashContext: context, using: adjustedCrashTimings, under: remoteRates, completion: completion)
        } else {
            DD.logger.debug("There was a crash in previous session, but it is ignored due to sampling.")
            completion(.processed)
        }

        return true
    }

    /// If the crash occurred in an existing RUM session and we know its `lastRUMViewEvent` we send the error using that session UUID and link
    /// the crash to that view. The error event can be preceded with a view update based on `Constants.viewEventAvailabilityThreshold` condition.
    private func sendCrashReportLinkedToLastViewInPreviousSession(
        _ crashReport: DDCrashReport,
        lastRUMViewEventInPreviousSession lastRUMViewEvent: RUMViewEvent,
        using crashTimings: AdjustedCrashTimings,
        bypassConsent: Bool,
        completion: @escaping (CrashReportOutcome) -> Void
    ) {
        if FatalErrorBuilder.canSendView(lastRUMViewEvent, errorDate: crashTimings.realCrashDate, now: crashTimings.realDateNow) {
            send(crashReport: crashReport, to: lastRUMViewEvent, using: crashTimings, bypassConsent: bypassConsent, completion: completion)
        } else {
            // We know it is too late for sending RUM view to previous RUM session as it is now stale on backend.
            // To avoid inconsistency, we only send the RUM error.
            DD.logger.debug("Sending crash as RUM error.")
            featureScope.eventWriteContext(bypassConsent: bypassConsent) { context, writer in
                let builder = createFatalErrorBuilder(context: context, crash: crashReport, crashDate: crashTimings.realCrashDate, timeSinceAppStart: crashTimings.timeSinceAppStart)
                let rumError = builder.createRUMError(with: lastRUMViewEvent)

                if let mappedError = self.eventsMapper.map(event: rumError) {
                    writer.write(value: mappedError, metadata: Data?.none, onResult: { completion(self.outcome(ofWritingError: $0)) })
                } else {
                    DD.logger.warn("errorEventMapper returned 'nil' for a crash. Discarding crashes is not supported. The unmodified event will be sent.")
                    writer.write(value: rumError, metadata: Data?.none, onResult: { completion(self.outcome(ofWritingError: $0)) })
                }
            }
        }
    }

    /// If the crash occurred in an existing RUM session and we know its `lastRUMSessionState` but there was no view to link it to, we can
    /// still send the error using that session UUID. No view means the session has not tracked one yet, the app was in background (see
    /// `lastViewSeen(in:)`) or the session was stopped.
    private func sendCrashReportToPreviousSession(
        _ crashReport: DDCrashReport,
        crashContext: CrashContext,
        lastRUMSessionStateInPreviousSession lastRUMSessionState: RUMSessionState,
        using crashTimings: AdjustedCrashTimings,
        under remoteRates: RemoteSamplingRates?,
        completion: @escaping (CrashReportOutcome) -> Void
    ) {
        let handlingRule = RUMOffViewEventsHandlingRule(
            applicationState: nil,
            sessionState: lastRUMSessionState,
            isAppInForeground: crashContext.lastIsAppInForeground,
            // FLASHCAT FORK - a crash is reported whether or not Background Events Tracking is
            // enabled. The option decides whether ordinary background activity is collected; a
            // crash is the one background event the application cannot afford to lose, so it is
            // always reported in a "Background" view of the session it happened in.
            isBETEnabled: true,
            command: nil
        )

        let newRUMView: RUMViewEvent?

        switch handlingRule {
        case .handleInApplicationLaunchView:
            // This indicates an edge case, where RUM session was created (we know the `lastRUMSessionState`), but no RUM view event
            // was yet passed to `CrashContext` (othwesiwe we would be calling `sendCrashReportLinkedToLastViewInPreviousSession()`).
            // It can happen if crash occurs shortly after starting first RUM session, but before we complete serializing first RUM view event in `CrashContext`.
            newRUMView = createNewRUMViewEvent(
                named: RUMOffViewEventsHandlingRule.Constants.applicationLaunchViewName,
                url: RUMOffViewEventsHandlingRule.Constants.applicationLaunchViewURL,
                startDate: crashTimings.realCrashDate,
                sessionUUID: RUMUUID(rawValue: lastRUMSessionState.sessionUUID), // link it to previous RUM Session
                context: crashContext,
                hasReplay: lastRUMSessionState.didStartWithReplay,
                drawnBy: lastRUMSessionState,
                under: remoteRates
            )
        case .handleInBackgroundView:
            // It means that the crash occurred as the very first event after sending app to background in previous session.
            // This is why we don't have the `lastRUMViewEvent` (no view was active), but we know the `lastRUMSessionState`.
            newRUMView = createNewRUMViewEvent(
                named: RUMOffViewEventsHandlingRule.Constants.backgroundViewName,
                url: RUMOffViewEventsHandlingRule.Constants.backgroundViewURL,
                startDate: crashTimings.realCrashDate,
                sessionUUID: RUMUUID(rawValue: lastRUMSessionState.sessionUUID), // link it to previous RUM Session
                context: crashContext,
                hasReplay: lastRUMSessionState.didStartWithReplay,
                drawnBy: lastRUMSessionState,
                under: remoteRates
            )
        case .doNotHandle:
            DD.logger.debug("There was a crash in previous session, but it is ignored due to sampling or the session being stopped.")
            newRUMView = nil
        }

        if let newRUMView = newRUMView {
            send(crashReport: crashReport, to: newRUMView, using: crashTimings, bypassConsent: canBypassConsent(crashContext), completion: completion)
        } else {
            completion(.processed)
        }
    }

    /// If the crash occurred before starting RUM session (after initializing SDK, but before starting the first view) we don't have any session UUID to associate the error with.
    /// In that case, we consider sending this crash within a new, single-view session: either "ApplicationLaunch" view or "Background" view.
    private func sendCrashReportToNewSession(
        _ crashReport: DDCrashReport,
        crashContext: CrashContext,
        using crashTimings: AdjustedCrashTimings,
        under remoteRates: RemoteSamplingRates?,
        completion: @escaping (CrashReportOutcome) -> Void
    ) {
        // There was no session, so there is no history of views: a crash in foreground happened during the
        // application launch, a crash in background happened in background. FLASHCAT FORK - it is reported in
        // background too, whether or not Background Events Tracking is enabled (see `sendCrashReportToPreviousSession()`).
        // The new session it creates was drawn by the sampler before getting here.
        let isAppInForeground = crashContext.lastIsAppInForeground
        let newRUMView = createNewRUMViewEvent(
            named: isAppInForeground
                ? RUMOffViewEventsHandlingRule.Constants.applicationLaunchViewName
                : RUMOffViewEventsHandlingRule.Constants.backgroundViewName,
            url: isAppInForeground
                ? RUMOffViewEventsHandlingRule.Constants.applicationLaunchViewURL
                : RUMOffViewEventsHandlingRule.Constants.backgroundViewURL,
            startDate: crashTimings.realCrashDate,
            sessionUUID: uuidGenerator.generateUnique(), // create new RUM session
            context: crashContext,
            // As the crash occurred after initializing SDK but before starting the first view,
            // we can't know if Session Replay was configured. However, lack of view implies
            // that there must be no replay collected:
            hasReplay: false,
            under: remoteRates
        )

        send(crashReport: crashReport, to: newRUMView, using: crashTimings, bypassConsent: canBypassConsent(crashContext), completion: completion)
    }

    /// Sends given `CrashReport` by linking it to given `rumView` and updating view counts accordingly.
    /// - Parameter completion: called once the events are written.
    private func send(
        crashReport: DDCrashReport,
        to rumView: RUMViewEvent,
        using crashTimings: AdjustedCrashTimings,
        bypassConsent: Bool,
        completion: @escaping (CrashReportOutcome) -> Void
    ) {
        DD.logger.debug("Updating RUM view with crash report.")

        featureScope.eventWriteContext(bypassConsent: bypassConsent) { context, writer in
            let builder = createFatalErrorBuilder(context: context, crash: crashReport, crashDate: crashTimings.realCrashDate, timeSinceAppStart: crashTimings.timeSinceAppStart)
            let updatedRUMView = builder.updateRUMViewWithError(rumView)
            let rumError = builder.createRUMError(with: updatedRUMView)

            let errorToWrite: RUMErrorEvent
            if let mappedError = self.eventsMapper.map(event: rumError) {
                errorToWrite = mappedError
            } else {
                DD.logger.warn("errorEventMapper returned 'nil' for a crash. Discarding crashes is not supported. The unmodified event will be sent.")
                errorToWrite = rumError
            }
            // Writes run in order, so `completion` goes with the last one. It reports what became of the error only: once
            // the error is written, writing the crash again would report it twice, so a failed view update is let go.
            if let mappedView = self.eventsMapper.map(event: updatedRUMView) {
                let errorOutcome = WriteResult()
                writer.write(value: errorToWrite, metadata: Data?.none, onResult: { errorOutcome.value = $0 })
                writer.write(value: self.eventsMapper.map(event: mappedView), metadata: Data?.none, onResult: { _ in
                    completion(self.outcome(ofWritingError: errorOutcome.value))
                })
            } else {
                writer.write(value: errorToWrite, metadata: Data?.none, onResult: { completion(self.outcome(ofWritingError: $0)) })
            }
        }
    }

    /// FLASHCAT FORK - the view the crash is linked to, if any.
    ///
    /// While its session lasts, the crash context keeps the last view even after that view stopped, because in
    /// foreground it is the last screen the user saw: a crash under a screen that is not tracked (a presented
    /// controller the predicate ignores, a system sheet) belongs to it rather than to no view at all.
    ///
    /// In background it is not: the user left that screen, and the view stopped because the app went away. A
    /// crash there has no view of its own, so it goes to the "Background" view of its session, exactly as it
    /// did while the context still dropped stopped views.
    private func lastViewSeen(in context: CrashContext) -> RUMViewEvent? {
        guard let view = context.lastRUMViewEvent else {
            return nil
        }
        let isStoppedView = view.view.isActive == false
        return isStoppedView && !context.lastIsAppInForeground ? nil : view
    }

    // MARK: - Building RUM events

    /// What became of the crash, given what became of its error event: a crash whose error can never be written is
    /// dropped, as reading it again would fail again.
    private func outcome(ofWritingError outcome: WriteOutcome) -> CrashReportOutcome {
        switch outcome {
        case .written:
            return .processed
        case .failedPermanently:
            featureScope.telemetry.error("[RUM] A crash cannot be written and is dropped")
            return .processed
        case .failedTransiently:
            return .writeFailed
        }
    }

    /// A crash recorded with `.granted` consent is written regardless of the current consent. A crash recorded
    /// with `.pending` consent is written under the current consent: Crash Reporting sends it only once consent is
    /// granted.
    private func canBypassConsent(_ crashContext: CrashContext) -> Bool {
        crashContext.trackingConsent == .granted
    }

    private func createFatalErrorBuilder(context: DatadogContext, crash: DDCrashReport, crashDate: Date, timeSinceAppStart: TimeInterval?) -> FatalErrorBuilder {
        return FatalErrorBuilder(
            context: context,
            error: .crash,
            errorUUID: uuidGenerator.generateUnique(),
            errorDate: crashDate,
            errorType: crash.type,
            errorMessage: crash.message,
            errorStack: crash.stack,
            errorThreads: crash.threads.toRUMDataFormat,
            errorBinaryImages: crash.binaryImages.toRUMDataFormat,
            errorWasTruncated: crash.wasTruncated,
            errorMeta: crash.meta.toRUMDataFormat,
            additionalAttributes: crash.additionalAttributes.dd.decode(),
            timeSinceAppStart: timeSinceAppStart
        )
    }

    /// Creates new RUM view event.
    private func createNewRUMViewEvent(
        named viewName: String,
        url viewURL: String,
        startDate: Date,
        sessionUUID: RUMUUID,
        context: CrashContext,
        hasReplay: Bool?,
        drawnBy drawnSession: RUMSessionState? = nil,
        under remoteRates: RemoteSamplingRates? = nil
    ) -> RUMViewEvent {
        let viewUUID = uuidGenerator.generateUnique()

        // The configuration this view reports. A session that really ran speaks for itself: its
        // own draw is on its stored state, and once the console is setting the rate the init value
        // is the one number we know did not decide it. A session being invented right here —
        // because the crash came before any session existed — has no draw of its own, so it
        // reports the configuration in force now, which is also the one that just decided whether
        // this crash is collected at all.
        //
        // A session kept only because it reports an error stands for itself, so it reports 0
        // whatever it was drawn at - exactly as its own events would have.
        let sampledForError = drawnSession?.sampledForError == true
        let drawnRate = sampledForError
            ? 0
            : drawnSession?.drawnSessionSampleRate ?? Double(drawnSessionSampleRate(under: remoteRates))
        let drawnVersion = drawnSession.map { $0.drawnConfigurationVersion } ?? remoteRates?.version

        return RUMViewEvent(
            dd: .init(
                browserSdkVersion: nil,
                cls: nil,
                configuration: .init(
                    rcVersion: drawnVersion.flatMap { $0 > 0 ? $0 : nil },
                    sessionReplaySampleRate: nil,
                    sessionSampleRate: drawnRate,
                    startSessionReplayRecordingManually: nil
                ),
                documentVersion: 1,
                pageStates: nil,
                replayStats: nil,
                session: .init(
                    plan: .plan1,
                    sessionPrecondition: nil
                )
            ),
            account: context.accountInfo.map { RUMAccount(accountInfo: $0) },
            application: .init(
                currentLocale: context.device.locale, id: applicationID
            ),
            buildVersion: context.buildNumber,
            ciTest: ciTest,
            connectivity: RUMConnectivity(
                networkInfo: context.networkConnectionInfo,
                carrierInfo: context.carrierInfo
            ),
            container: nil,
            // RUM-3588: We know that last RUM view is not available, so we're creating a new one. No matter that, try using last
            // RUM attributes if available. There is a chance of having them as global RUM attributes can be updated more often than RUM view.
            // See https://github.com/DataDog/dd-sdk-ios/pull/1834 for more context.
            context: context.lastRUMAttributes,
            date: startDate.timeIntervalSince1970.dd.toInt64Milliseconds,
            ddtags: context.ddTags,
            device: context.device,
            display: nil,
            // RUMM-2197: In very rare cases, the OS info computed below might not be exactly the one
            // that the app crashed on. This would correspond to a scenario when the device OS was upgraded
            // before restarting the app after crash. To solve this, the OS information would have to be
            // persisted in `crashContext` the same way as we do for other dynamic information.
            os: context.os,
            privacy: nil,
            service: context.service,
            session: .init(
                hasReplay: hasReplay,
                id: sessionUUID.toRUMDataFormat,
                isActive: true,
                sampledForError: sampledForError ? true : nil,
                sampledForReplay: nil,
                type: ciTest != nil ? .ciTest : (syntheticsTest != nil ? .synthetics : .user)
            ),
            source: .init(rawValue: context.source) ?? .ios,
            synthetics: syntheticsTest,
            usr: context.userInfo.map { RUMUser(userInfo: $0) },
            version: context.version,
            view: .init(
                action: .init(count: 0),
                cpuTicksCount: nil,
                cpuTicksPerSecond: nil,
                crash: .init(count: 0),
                cumulativeLayoutShift: nil,
                cumulativeLayoutShiftTargetSelector: nil,
                cumulativeLayoutShiftTime: nil,
                customTimings: nil,
                domComplete: nil,
                domContentLoaded: nil,
                domInteractive: nil,
                error: .init(count: 0),
                firstByte: nil,
                firstContentfulPaint: nil,
                firstInputDelay: nil,
                firstInputTargetSelector: nil,
                firstInputTime: nil,
                flutterBuildTime: nil,
                flutterRasterTime: nil,
                freezeRate: nil,
                frozenFrame: .init(count: 0),
                frustration: .init(count: 0),
                id: viewUUID.toRUMDataFormat,
                inForegroundPeriods: nil,
                interactionToNextPaint: nil,
                interactionToNextPaintTargetSelector: nil,
                interactionToNextPaintTime: nil,
                interactionToNextViewTime: nil,
                isActive: false, // we know it won't receive updates
                isSlowRendered: false,
                jsRefreshRate: nil,
                largestContentfulPaint: nil,
                largestContentfulPaintTargetSelector: nil,
                loadEvent: nil,
                loadingTime: nil,
                loadingType: nil,
                longTask: .init(count: 0),
                memoryAverage: nil,
                memoryMax: nil,
                name: viewName,
                networkSettledTime: nil,
                referrer: nil,
                refreshRateAverage: nil,
                refreshRateMin: nil,
                resource: .init(count: 0),
                slowFrames: nil,
                slowFramesRate: nil,
                timeSpent: 1, // arbitrary, 1ns duration
                url: viewURL
            )
        )
    }
}

/// The result of a write, read by the write that follows it on the same serial writer queue.
private final class WriteResult {
    var value: WriteOutcome = .written
}
