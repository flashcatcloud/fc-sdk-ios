/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

#if os(iOS)
import Foundation
import DatadogInternal

/// A type managing Session Replay recording.
internal protocol Recording {
    func captureNextRecord(_ recorderContext: Recorder.Context) throws
}

/// The main engine and the heart beat of Session Replay.
///
/// It instruments running application by observing current window(s) and
/// captures intermediate representation of the view hierarchy. This representation
/// is later passed to `Processor` and turned into wireframes uploaded to the BE.
@_spi(Internal)
public class Recorder: Recording {
    /// The context of recording next snapshot.
    public struct Context {
        /// The content recording policy for texts and inputs at the moment of requesting snapshot.
        public let textAndInputPrivacy: TextAndInputPrivacyLevel
        /// The image recording policy from the moment of requesting snapshot.
        public let imagePrivacy: ImagePrivacyLevel
        /// The content recording policy from the moment of requesting snapshot.
        public let touchPrivacy: TouchPrivacyLevel
        /// Current RUM application ID - standard UUID string, lowecased.
        let applicationID: String
        /// Current RUM session ID - standard UUID string, lowecased.
        let sessionID: String
        /// Current RUM view ID - standard UUID string, lowecased.
        let viewID: String
        /// Current view related server time offset
        let viewServerTimeOffset: TimeInterval?
        /// The time of requesting this snapshot.
        let date: Date
        /// The telemetry instance to report to.
        let telemetry: Telemetry
        /// FLASHCAT FORK - whether the records of this replay are withheld until its session
        /// reports an error, and whether that release is already on its way.
        let replayHold: ReplayHold
        /// FLASHCAT FORK - the tracking consent at the moment of requesting the snapshot. Records
        /// withheld without consent are thrown away rather than released once it is granted.
        let trackingConsent: TrackingConsent

        internal init(
            textAndInputPrivacy: TextAndInputPrivacyLevel,
            imagePrivacy: ImagePrivacyLevel,
            touchPrivacy: TouchPrivacyLevel,
            applicationID: String,
            sessionID: String,
            viewID: String,
            viewServerTimeOffset: TimeInterval?,
            date: Date,
            telemetry: Telemetry,
            replayHold: ReplayHold = .none,
            trackingConsent: TrackingConsent = .granted
        ) {
            self.textAndInputPrivacy = textAndInputPrivacy
            self.imagePrivacy = imagePrivacy
            self.touchPrivacy = touchPrivacy
            self.applicationID = applicationID
            self.sessionID = sessionID
            self.viewID = viewID
            self.viewServerTimeOffset = viewServerTimeOffset
            self.date = date
            self.telemetry = telemetry
            self.replayHold = replayHold
            self.trackingConsent = trackingConsent
        }
    }

    /// FLASHCAT FORK - what happens to the records of a replay kept only in case its session
    /// reports an error.
    public enum ReplayHold {
        /// The records are written as they are recorded.
        case none
        /// The records are withheld, and thrown away when the view or the session changes.
        case withheld
        /// The session has reported its error and its events are on their way out: the records
        /// are still withheld so they never reach the backend ahead of the events, but nothing
        /// throws them away any more - a view change included.
        case releasePending
    }

    /// Swizzles `UIApplication` for recording touch events.
    private let uiApplicationSwizzler: UIApplicationSwizzler
    /// Captures view tree snapshot (an intermediate representation of the view tree).
    private let viewTreeSnapshotProducer: ViewTreeSnapshotProducer
    /// Captures touch snapshot.
    private let touchSnapshotProducer: TouchSnapshotProducer
    /// Turns view tree snapshots into data models that will be uploaded to SR BE.
    private let snapshotProcessor: SnapshotProcessing

    convenience init(
        snapshotProcessor: SnapshotProcessing,
        additionalNodeRecorders: [NodeRecorder],
        featureFlags: SessionReplay.Configuration.FeatureFlags
    ) throws {
        let windowObserver = KeyWindowObserver()
        let viewTreeSnapshotProducer = WindowViewTreeSnapshotProducer(
            windowObserver: windowObserver,
            snapshotBuilder: ViewTreeSnapshotBuilder(
                additionalNodeRecorders: additionalNodeRecorders,
                featureFlags: featureFlags
            )
        )
        let touchSnapshotProducer = WindowTouchSnapshotProducer(windowObserver: windowObserver)

        self.init(
            uiApplicationSwizzler: try UIApplicationSwizzler(handler: touchSnapshotProducer),
            viewTreeSnapshotProducer: viewTreeSnapshotProducer,
            touchSnapshotProducer: touchSnapshotProducer,
            snapshotProcessor: snapshotProcessor
        )
    }

    init(
        uiApplicationSwizzler: UIApplicationSwizzler,
        viewTreeSnapshotProducer: ViewTreeSnapshotProducer,
        touchSnapshotProducer: TouchSnapshotProducer,
        snapshotProcessor: SnapshotProcessing
    ) {
        self.uiApplicationSwizzler = uiApplicationSwizzler
        self.viewTreeSnapshotProducer = viewTreeSnapshotProducer
        self.touchSnapshotProducer = touchSnapshotProducer
        self.snapshotProcessor = snapshotProcessor
        uiApplicationSwizzler.swizzle()
    }

    deinit {
        uiApplicationSwizzler.unswizzle()
    }

    // MARK: - Recording

    /// Initiates the capture of a next record.
    /// **Note**: This is called on the main thread.
    func captureNextRecord(_ recorderContext: Context) throws {
        guard let viewTreeSnapshot = try viewTreeSnapshotProducer.takeSnapshot(with: recorderContext) else {
            // There is nothing visible yet (i.e. the key window is not yet ready).
            return
        }

        let touchSnapshot = touchSnapshotProducer.takeSnapshot(context: recorderContext)
        snapshotProcessor.process(viewTreeSnapshot: viewTreeSnapshot, touchSnapshot: touchSnapshot)
    }
}
#endif
