/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

#if os(iOS)
import Foundation
import DatadogInternal

/// A type turning succeeding view-tree and touch snapshots into sequence of Mobile Session Replay records.
///
/// This is the actual brain of Session Replay. Based on the sequence of snapshots it receives, it computes the sequence
/// of records that will to be send to SR BE. It implements the logic of reducing snapshots into Full or Incremental
/// mutation records.
internal protocol SnapshotProcessing {
    /// Accepts next view-tree and touch snapshots.
    /// - Parameter viewTreeSnapshot: the snapshot of a next view tree
    /// - Parameter touchSnapshot: the snapshot of next touch interactions (or `nil` if no interactions happened)
    func process(viewTreeSnapshot: ViewTreeSnapshot, touchSnapshot: TouchSnapshot?)
    /// FLASHCAT FORK - throws away the records withheld until the session reports an error, see
    /// `Recording.discardWithheldRecords()`.
    func discardWithheldRecords()
}

/// The brain of the Session Replay.
///
/// It receives `ViewTreeSnapshots` (VTS) from `Recorder` and turns them
/// into format understood by SR BE, so it can be replayed in the player.
///
/// VTSs processing is following:
/// - the VTS is broke apart into individual view snapshots, mapped into array of SR wireframes (see `WireframesBuilder`);
/// - the array of wireframes is attached to SR record (see `RecordsBuidler`);
/// - succeeding records are enriched with their RUM context and written to `DatadogCore`;
/// - when `DatadogCore` triggers an upload, batched records are deserialized, grouped into SR segments and then uploaded.
internal class SnapshotProcessor: SnapshotProcessing {
    /// Flattens VTS received from `Recorder` by removing invisible nodes.
    private let nodesFlattener = NodesFlattener()
    /// Builds SR records to transport SR wireframes.
    private let recordsBuilder: RecordsBuilder

    /// The background queue for executing all logic.
    private let queue: Queue
    /// Writes records to `DatadogCore`.
    private let recordWriter: RecordWriting
    /// Processes resources on a background thread.
    private let resourceProcessor: ResourceProcessing
    /// Sends telemetry through sdk core.
    private let telemetry: Telemetry

    /// Last processed snapshot.
    private var lastSnapshot: ViewTreeSnapshot? = nil
    /// Wireframes from last "full snapshot" or "incremental snapshot" record.
    private var lastWireframes: [SRWireframe]? = nil

    /// Interception callback for snapshot tests.
    /// Only available in Debug configuration, solely made for testing purpose.
    var interceptWireframes: (([SRWireframe]) -> Void)? = nil

    private var srContextPublisher: SRContextPublisher

    private var recordsCountByViewID: [String: Int64] = [:]

    /// FLASHCAT FORK - the records of a replay withheld until its session reports an error: one
    /// segment, the current view's, starting with a full snapshot, with the resources (images)
    /// its records reference. Nothing in it is written until the session errors; it is thrown
    /// away when the view or the session changes, once it spans more than
    /// `withheldReplayDuration`, or once it holds more than `withheldReplayRecordsLimit` records
    /// or `withheldReplayResourcesLimit` resources, and recording restarts from a full snapshot.
    private var withheldRecords: [EnrichedRecord] = []
    private var withheldRecordsCount = 0
    /// Each resource once, by identifier: the builder reports every image's resource on every
    /// snapshot, and the budget is meant for distinct images, not for snapshots.
    private var withheldResources: [Resource] = []
    private var withheldResourceIdentifiers: Set<String> = []
    private var withheldSince: Date?
    /// How many withheld segments were thrown away before the one finally released.
    private var droppedWithheldSegments = 0
    /// The span a withheld replay may cover - the same minute the withheld events promise.
    static let withheldReplayDuration: TimeInterval = 60
    /// Memory bounds of a withheld segment, whatever its span.
    static let withheldReplayRecordsLimit = 2_000
    static let withheldReplayResourcesLimit = 100

    init(
        queue: Queue,
        recordWriter: RecordWriting,
        resourceProcessor: ResourceProcessing,
        srContextPublisher: SRContextPublisher,
        telemetry: Telemetry
    ) {
        self.queue = queue
        self.recordWriter = recordWriter
        self.resourceProcessor = resourceProcessor
        self.srContextPublisher = srContextPublisher
        self.telemetry = telemetry
        self.recordsBuilder = RecordsBuilder(telemetry: telemetry)
    }

    // MARK: - Processing

    func process(viewTreeSnapshot: ViewTreeSnapshot, touchSnapshot: TouchSnapshot?) {
        queue.run { [weak self] in self?.processSync(viewTreeSnapshot: viewTreeSnapshot, touchSnapshot: touchSnapshot) }
    }

    func discardWithheldRecords() {
        queue.run { [weak self] in self?.discardWithheldRecordsAndRestart() }
    }

    /// Throws away what is withheld and makes the next snapshot start a new segment, from a full
    /// snapshot: incremental records cannot follow a dropped history.
    private func discardWithheldRecordsAndRestart() {
        discardWithheldRecords(sameSession: false)
        lastSnapshot = nil
        lastWireframes = nil
    }

    private func processSync(viewTreeSnapshot: ViewTreeSnapshot, touchSnapshot: TouchSnapshot?) {
        if viewTreeSnapshot.context.replayHold != .none && viewTreeSnapshot.context.trackingConsent == .notGranted {
            // Nothing recorded without consent may be released once it is granted: what is held
            // is thrown away and nothing is held until consent returns, when the segment starts
            // over from a full snapshot. A replay that is not withheld is written as usual, to a
            // writer that drops it.
            discardWithheldRecordsAndRestart()
            return
        }
        let mustRestartSegment = settleWithheldRecords(for: viewTreeSnapshot.context)
        let builder = WireframesBuilder(webViewSlotIDs: viewTreeSnapshot.webViewSlotIDs)
        let nodes = nodesFlattener.flattenNodes(in: viewTreeSnapshot)

        // build wireframe from nodes
        var wireframes: [SRWireframe] = nodes.flatMap { node in
            node.wireframesBuilder.buildWireframes(with: builder)
        }

        // build hidden webview wireframes and place them at the beginning
        wireframes = builder.hiddenWebViewWireframes() + wireframes

        interceptWireframes?(wireframes)

        var records: [SRRecord] = []
        // Create records for describing UI:
        if mustRestartSegment ||
            viewTreeSnapshot.context.applicationID != lastSnapshot?.context.applicationID ||
            viewTreeSnapshot.context.sessionID != lastSnapshot?.context.sessionID ||
            viewTreeSnapshot.context.viewID != lastSnapshot?.context.viewID {
            // If RUM context ids have changed, new segment should be started.
            // Segment must always start with "meta" → "focus" → "full snapshot" records.
            records.append(recordsBuilder.createMetaRecord(from: viewTreeSnapshot))
            records.append(recordsBuilder.createFocusRecord(from: viewTreeSnapshot))
            records.append(recordsBuilder.createFullSnapshotRecord(from: viewTreeSnapshot, wireframes: wireframes))
        } else if let lastWireframes = lastWireframes {
            // No change to RUM context means we're recording new records within the same RUM view.
            // Such can be added to current segment.
            // Prefer creating "incremental snapshot" records but fallback to "full snapshot" (unexpected):
            let record = recordsBuilder.createIncrementalSnapshotRecord(from: viewTreeSnapshot, with: wireframes, lastWireframes: lastWireframes)
            record.flatMap { records.append($0) }

            // Create viewport orientation change record
            if let lastSnapshot = lastSnapshot {
                recordsBuilder.createViewport(
                    from: viewTreeSnapshot,
                    lastSnapshot: lastSnapshot
                )
                .flatMap { records.append($0) }
            }
        } else {
            telemetry.error("[SR] Unexpected flow in `Processor`: no previous wireframes and no previous RUM context")
            records.append(recordsBuilder.createFullSnapshotRecord(from: viewTreeSnapshot, wireframes: wireframes))
        }

        // Create records for denoting touch interaction:
        if let touchSnapshot = touchSnapshot {
            records.append(
                contentsOf: recordsBuilder.createIncrementalSnapshotRecords(from: touchSnapshot)
            )
        }

        if !records.isEmpty {
            // Transform `[SRRecord]` to `EnrichedRecord` so we can write it to `DatadogCore` and
            // later read it back (as `EnrichedRecordJSON`) for preparing upload request(s):
            let enrichedRecord = EnrichedRecord(context: viewTreeSnapshot.context, records: records)
            trackRecord(key: enrichedRecord.viewID, value: Int64(records.count))

            if viewTreeSnapshot.context.replayHold != .none {
                if withheldRecords.isEmpty {
                    withheldSince = viewTreeSnapshot.context.date
                }
                withheldRecords.append(enrichedRecord)
                withheldRecordsCount += records.count
            } else {
                recordWriter.write(nextRecord: enrichedRecord)
            }
        }

        // Track state:
        lastSnapshot = viewTreeSnapshot
        lastWireframes = wireframes

        if viewTreeSnapshot.context.replayHold != .none {
            // Uploading the images of a replay that may never be uploaded would cost the
            // application the very upload it chose to avoid. They wait with the segment, and are
            // not marked processed until they actually go.
            for resource in builder.resources where withheldResourceIdentifiers.insert(resource.calculateIdentifier()).inserted {
                withheldResources.append(resource)
            }
        } else {
            resourceProcessor.process(
                resources: builder.resources,
                context: .init(viewTreeSnapshot.context.applicationID)
            )
        }
    }

    private func trackRecord(key: String, value: Int64) {
        recordsCountByViewID[key, default: 0] += value
        srContextPublisher.setRecordsCountByViewID(recordsCountByViewID)
    }

    // MARK: - Withheld replay (FLASHCAT FORK)

    /// Releases or throws away what is withheld, before the given snapshot is processed.
    ///
    /// - Returns: `true` when the withheld segment of this very view was thrown away, so the
    ///   snapshot must start a new segment: incremental records cannot follow a dropped history.
    private func settleWithheldRecords(for context: Recorder.Context) -> Bool {
        guard let first = withheldRecords.first, let since = withheldSince else {
            return false
        }
        let sameSession = first.applicationID == context.applicationID && first.sessionID == context.sessionID
        if sameSession && context.replayHold == .none {
            // The session reported its error (or was forced): the segment goes out as recorded.
            withheldRecords.forEach { recordWriter.write(nextRecord: $0) }
            resourceProcessor.process(resources: withheldResources, context: .init(first.applicationID))
            telemetry.debug(
                "Error session replay released",
                attributes: [
                    "segment.records_count": withheldRecordsCount,
                    "segment.duration_ms": Int64(context.date.timeIntervalSince(since) * 1_000),
                    "segment.dropped_before": droppedWithheldSegments
                ]
            )
            clearWithheldRecords()
            droppedWithheldSegments = 0
            return false
        }
        if sameSession && context.replayHold == .releasePending {
            // The session's error is reported and the release is on its way: a view change no
            // longer throws the segment away, or an error followed by a screen change - the
            // usual way an app shows one - would lose the replay of the screen it happened on.
            // The segment of the new view is held behind it and goes out with it.
            return false
        }
        let sameView = sameSession && first.viewID == context.viewID
        let outgrown = context.date.timeIntervalSince(since) > Self.withheldReplayDuration
            || withheldRecordsCount > Self.withheldReplayRecordsLimit
            || withheldResources.count > Self.withheldReplayResourcesLimit
        guard !sameView || outgrown else {
            return false
        }
        // Thrown away: the view or the session changed, or the segment outgrew the window.
        discardWithheldRecords(sameSession: sameSession)
        return sameView
    }

    /// Throws away what is withheld. What it counted is given back, so no view claims a replay
    /// that was never uploaded.
    private func discardWithheldRecords(sameSession: Bool) {
        guard !withheldRecords.isEmpty else {
            return
        }
        for record in withheldRecords {
            let remaining = (recordsCountByViewID[record.viewID] ?? 0) - Int64(record.records.count)
            recordsCountByViewID[record.viewID] = remaining > 0 ? remaining : nil
        }
        srContextPublisher.setRecordsCountByViewID(recordsCountByViewID)
        droppedWithheldSegments = sameSession ? droppedWithheldSegments + 1 : 0
        clearWithheldRecords()
    }

    private func clearWithheldRecords() {
        withheldRecords = []
        withheldRecordsCount = 0
        withheldResources = []
        withheldResourceIdentifiers = []
        withheldSince = nil
    }
}
#endif
