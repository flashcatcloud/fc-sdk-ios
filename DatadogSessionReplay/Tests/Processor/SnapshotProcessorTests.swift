/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

#if os(iOS)
import XCTest
import WebKit
import DatadogInternal
@_spi(Internal)
import TestUtilities
@_spi(Internal)
@testable import DatadogSessionReplay

private class RecordWriterMock: RecordWriting {
    var records: [EnrichedRecord] = []

    func write(nextRecord: EnrichedRecord) { records.append(nextRecord) }
}

class SnapshotProcessorTests: XCTestCase {
    private let recordWriter = RecordWriterMock()

    // MARK: - Processing `ViewTreeSnapshots`

    func testWhenProcessingFirstViewTreeSnapshot_itWritesRecordsThatIndicateStartOfASegment() throws {
        let time = Date()
        let rum: RUMCoreContext = .mockWith(serverTimeOffset: 0)

        // Given
        let core = PassthroughCoreMock()
        let srContextPublisher = SRContextPublisher(core: core)
        let resourceProcessor = ResourceProcessorSpy()
        let processor = SnapshotProcessor(
            queue: NoQueue(),
            recordWriter: recordWriter,
            resourceProcessor: resourceProcessor,
            srContextPublisher: srContextPublisher,
            telemetry: TelemetryMock()
        )
        let viewTree = generateSimpleViewTree()

        // When
        let snapshot = generateViewTreeSnapshot(for: viewTree, date: time, rumContext: rum)
        processor.process(viewTreeSnapshot: snapshot, touchSnapshot: nil)

        // Then
        XCTAssertEqual(recordWriter.records.count, 1)
        XCTAssertTrue(resourceProcessor.resources.isEmpty)

        let enrichedRecord = try XCTUnwrap(recordWriter.records.first)
        XCTAssertEqual(enrichedRecord.applicationID, rum.applicationID)
        XCTAssertEqual(enrichedRecord.sessionID, rum.sessionID)
        XCTAssertEqual(enrichedRecord.viewID, rum.viewID)

        XCTAssertEqual(enrichedRecord.records.count, 3, "Segment must start with 'meta' → 'focus' → 'full snapshot' records")
        XCTAssertTrue(enrichedRecord.records[0].isMetaRecord)
        XCTAssertTrue(enrichedRecord.records[1].isFocusRecord)
        XCTAssertTrue(enrichedRecord.records[2].isFullSnapshotRecord)

        XCTAssertEqual(core.recordsCountByViewID, ["abc": 3])
    }

    func testWhenRUMContextDoesNotChangeInSucceedingViewTreeSnapshots_itWritesRecordsThatContinueCurrentSegment() {
        let time = Date()
        let rum: RUMCoreContext = .mockWith(serverTimeOffset: 0)

        // Given
        let core = PassthroughCoreMock()
        let srContextPublisher = SRContextPublisher(core: core)
        let processor = SnapshotProcessor(
            queue: NoQueue(),
            recordWriter: recordWriter,
            resourceProcessor: ResourceProcessorSpy(),
            srContextPublisher: srContextPublisher,
            telemetry: TelemetryMock()
        )
        let viewTree = generateSimpleViewTree()

        // When
        let snapshot1 = generateViewTreeSnapshot(for: viewTree, date: time, rumContext: rum)
        let snapshot2 = generateViewTreeSnapshot(for: morphed(viewTree: viewTree), date: time.addingTimeInterval(1), rumContext: rum)
        let snapshot3 = generateViewTreeSnapshot(for: morphed(viewTree: viewTree), date: time.addingTimeInterval(2), rumContext: rum)

        processor.process(viewTreeSnapshot: snapshot1, touchSnapshot: nil)
        processor.process(viewTreeSnapshot: snapshot2, touchSnapshot: nil)
        processor.process(viewTreeSnapshot: snapshot3, touchSnapshot: nil)

        // Then
        let enrichedRecords = recordWriter.records
        XCTAssertEqual(recordWriter.records.count, 3)

        XCTAssertEqual(enrichedRecords[0].records.count, 3, "Segment must start with 'meta' → 'focus' → 'full snapshot' records")
        XCTAssertTrue(enrichedRecords[0].records[0].isMetaRecord)
        XCTAssertTrue(enrichedRecords[0].records[1].isFocusRecord)
        XCTAssertTrue(enrichedRecords[0].records[2].isFullSnapshotRecord)

        XCTAssertEqual(enrichedRecords[1].records.count, 1, "It should follow with 'incremental snapshot' record")
        XCTAssertTrue(enrichedRecords[1].records[0].isIncrementalSnapshotRecord)

        XCTAssertEqual(enrichedRecords[2].records.count, 1, "It should follow with 'incremental snapshot' record")
        XCTAssertTrue(enrichedRecords[2].records[0].isIncrementalSnapshotRecord)

        enrichedRecords.enumerated().forEach { index, enrichedRecord in
            XCTAssertEqual(enrichedRecord.applicationID, rum.applicationID)
            XCTAssertEqual(enrichedRecord.sessionID, rum.sessionID)
            XCTAssertEqual(enrichedRecord.viewID, rum.viewID)
        }

        XCTAssertEqual(core.recordsCountByViewID, ["abc": 5])
    }

    func testWhenOrientationChanges_itWritesRecordsViewportResizeDataSegment() {
        let time = Date()
        let rum: RUMCoreContext = .mockRandom()

        // Given
        let core = PassthroughCoreMock()
        let srContextPublisher = SRContextPublisher(core: core)
        let processor = SnapshotProcessor(
            queue: NoQueue(),
            recordWriter: recordWriter,
            resourceProcessor: ResourceProcessorSpy(),
            srContextPublisher: srContextPublisher,
            telemetry: TelemetryMock()
        )
        let view = UIView.mock(withFixture: .visible(.someAppearance))
        view.frame = CGRect(x: 0, y: 0, width: 100, height: 200)
        let rotatedView = UIView.mock(withFixture: .visible(.someAppearance))
        rotatedView.frame = CGRect(x: 0, y: 0, width: 200, height: 100)

        // When
        let snapshot1 = generateViewTreeSnapshot(for: view, date: time, rumContext: rum)
        let snapshot2 = generateViewTreeSnapshot(for: rotatedView, date: time.addingTimeInterval(1), rumContext: rum)

        processor.process(viewTreeSnapshot: snapshot1, touchSnapshot: nil)
        processor.process(viewTreeSnapshot: snapshot2, touchSnapshot: nil)

        // Then
        let enrichedRecords = recordWriter.records
        XCTAssertEqual(recordWriter.records.count, 2)

        XCTAssertEqual(enrichedRecords[0].records.count, 3, "Segment must start with 'meta' → 'focus' → 'full snapshot' records")
        XCTAssertTrue(enrichedRecords[0].records[0].isMetaRecord)
        XCTAssertTrue(enrichedRecords[0].records[1].isFocusRecord)
        XCTAssertTrue(enrichedRecords[0].records[2].isFullSnapshotRecord)

        XCTAssertEqual(enrichedRecords[1].records.count, 2, "It should follow with 'incremental snapshot' records")
        XCTAssertTrue(enrichedRecords[1].records[0].isIncrementalSnapshotRecord)
        XCTAssertTrue(enrichedRecords[1].records[1].isIncrementalSnapshotRecord)
        XCTAssertEqual(enrichedRecords[1].records[1].incrementalSnapshot?.viewportResizeData?.height, 100)
        XCTAssertEqual(enrichedRecords[1].records[1].incrementalSnapshot?.viewportResizeData?.width, 200)

        XCTAssertEqual(core.recordsCountByViewID?.values.first, 5)
    }

    func testWhenRUMContextChangesInSucceedingViewTreeSnapshots_itWritesRecordsThatIndicateNextSegments() {
        let time = Date()
        let rum1: RUMCoreContext = .mockRandom()
        let rum2: RUMCoreContext = .mockRandom()

        // Given
        let core = PassthroughCoreMock()
        let srContextPublisher = SRContextPublisher(core: core)
        let processor = SnapshotProcessor(
            queue: NoQueue(),
            recordWriter: recordWriter,
            resourceProcessor: ResourceProcessorSpy(),
            srContextPublisher: srContextPublisher,
            telemetry: TelemetryMock()
        )
        let viewTree = generateSimpleViewTree()

        // When
        let snapshot1 = generateViewTreeSnapshot(for: viewTree, date: time, rumContext: rum1)
        let snapshot2 = generateViewTreeSnapshot(for: morphed(viewTree: viewTree), date: time.addingTimeInterval(1), rumContext: rum1)
        let snapshot3 = generateViewTreeSnapshot(for: morphed(viewTree: viewTree), date: time.addingTimeInterval(2), rumContext: rum2)
        let snapshot4 = generateViewTreeSnapshot(for: morphed(viewTree: viewTree), date: time.addingTimeInterval(3), rumContext: rum2)

        processor.process(viewTreeSnapshot: snapshot1, touchSnapshot: nil)
        processor.process(viewTreeSnapshot: snapshot2, touchSnapshot: nil)
        processor.process(viewTreeSnapshot: snapshot3, touchSnapshot: nil)
        processor.process(viewTreeSnapshot: snapshot4, touchSnapshot: nil)

        // Then
        let enrichedRecords = recordWriter.records
        XCTAssertEqual(recordWriter.records.count, 4)

        XCTAssertEqual(enrichedRecords[0].records.count, 3, "Segment must start with 'meta' → 'focus' → 'full snapshot' records")
        XCTAssertTrue(enrichedRecords[0].records[0].isMetaRecord)
        XCTAssertTrue(enrichedRecords[0].records[1].isFocusRecord)
        XCTAssertTrue(enrichedRecords[0].records[2].isFullSnapshotRecord)

        XCTAssertEqual(enrichedRecords[1].records.count, 1, "It should follow with 'incremental snapshot' record")
        XCTAssertTrue(enrichedRecords[1].records[0].isIncrementalSnapshotRecord)

        XCTAssertEqual(enrichedRecords[2].records.count, 3, "Next segment must start with 'meta' → 'focus' → 'full snapshot' records")
        XCTAssertTrue(enrichedRecords[2].records[0].isMetaRecord)
        XCTAssertTrue(enrichedRecords[2].records[1].isFocusRecord)
        XCTAssertTrue(enrichedRecords[2].records[2].isFullSnapshotRecord)

        XCTAssertEqual(enrichedRecords[3].records.count, 1, "Next segment should follow with 'incremental snapshot' record")
        XCTAssertTrue(enrichedRecords[3].records[0].isIncrementalSnapshotRecord)

        zip(enrichedRecords, [rum1, rum1, rum2, rum2]).forEach { enrichedRecord, expectedRUM in
            XCTAssertEqual(enrichedRecord.applicationID, expectedRUM.applicationID)
            XCTAssertEqual(enrichedRecord.sessionID, expectedRUM.sessionID)
            XCTAssertEqual(enrichedRecord.viewID, expectedRUM.viewID)
        }

        XCTAssertEqual(core.recordsCountByViewID?.values.map { $0 }, [4, 4])
    }

    func testWhenProcessingViewTreeSnapshot_itIncludeWebViewSlotFromNode() throws {
        let time = Date()
        let rum: RUMCoreContext = .mockWith(serverTimeOffset: 0)

        // Given
        let core = PassthroughCoreMock()
        let srContextPublisher = SRContextPublisher(core: core)
        let processor = SnapshotProcessor(
            queue: NoQueue(),
            recordWriter: recordWriter,
            resourceProcessor: ResourceProcessorSpy(),
            srContextPublisher: srContextPublisher,
            telemetry: TelemetryMock()
        )

        let hiddenSlot: Int = .mockRandom()
        let visibleSlot: Int = .mockRandom(otherThan: [hiddenSlot])
        let builder = WKWebViewWireframesBuilder(slotID: visibleSlot, attributes: .mockAny())
        let node = Node(viewAttributes: .mockAny(), wireframesBuilder: builder)

        // When
        let snapshot = ViewTreeSnapshot(
            date: time,
            context: .init(
                textAndInputPrivacy: .mockRandom(),
                imagePrivacy: .mockRandom(),
                touchPrivacy: .mockRandom(),
                rumContext: rum,
                date: time
            ),
            viewportSize: .mockRandom(minWidth: 1_000, minHeight: 1_000),
            nodes: [node],
            webViewSlotIDs: Set([hiddenSlot, visibleSlot])
        )

        processor.process(viewTreeSnapshot: snapshot, touchSnapshot: nil)

        // Then
        XCTAssertEqual(recordWriter.records.count, 1)

        let enrichedRecord = try XCTUnwrap(recordWriter.records.first)
        XCTAssertEqual(enrichedRecord.applicationID, rum.applicationID)
        XCTAssertEqual(enrichedRecord.sessionID, rum.sessionID)
        XCTAssertEqual(enrichedRecord.viewID, rum.viewID)

        XCTAssertEqual(enrichedRecord.records.count, 3)
        XCTAssertTrue(enrichedRecord.records[2].isFullSnapshotRecord)
        let fullSnapshotRecord = try XCTUnwrap(enrichedRecord.records[2].fullSnapshot)
        XCTAssertEqual(fullSnapshotRecord.data.wireframes.count, 2)

        XCTAssertEqual(fullSnapshotRecord.data.wireframes.first?.id, Int64(hiddenSlot), "The hidden webview wireframe should be first")
        XCTAssertEqual(fullSnapshotRecord.data.wireframes.last?.id, Int64(visibleSlot), "The visible webview wireframe should be last")
    }

    func testWhenProcessingViewTreeSnapshot_itIncludeWebViewSlotFromCache() throws {
        let time = Date()
        let rum: RUMCoreContext = .mockWith(serverTimeOffset: 0)

        // Given
        let core = PassthroughCoreMock()
        let srContextPublisher = SRContextPublisher(core: core)
        let processor = SnapshotProcessor(
            queue: NoQueue(),
            recordWriter: recordWriter,
            resourceProcessor: ResourceProcessorSpy(),
            srContextPublisher: srContextPublisher,
            telemetry: TelemetryMock()
        )

        let webview = WKWebView()
        let viewTree = generateSimpleViewTree()

        // When
        snapshotBuilder.webViewCache.add(webview)
        let snapshot = generateViewTreeSnapshot(for: viewTree, date: time, rumContext: rum)
        processor.process(viewTreeSnapshot: snapshot, touchSnapshot: nil)

        // Then
        XCTAssertEqual(recordWriter.records.count, 1)

        let enrichedRecord = try XCTUnwrap(recordWriter.records.first)
        XCTAssertEqual(enrichedRecord.applicationID, rum.applicationID)
        XCTAssertEqual(enrichedRecord.sessionID, rum.sessionID)
        XCTAssertEqual(enrichedRecord.viewID, rum.viewID)

        XCTAssertEqual(enrichedRecord.records.count, 3)
        XCTAssertTrue(enrichedRecord.records[2].isFullSnapshotRecord)
        let fullSnapshotRecord = try XCTUnwrap(enrichedRecord.records[2].fullSnapshot)
        XCTAssertEqual(fullSnapshotRecord.data.wireframes.count, 3)
        XCTAssertEqual(fullSnapshotRecord.data.wireframes.first?.id, Int64(webview.hash), "The hidden webview wireframe should be first")
    }

    func testWhenProcessingViewTreeSnapshot_itRecordsResources() throws {
        let resource: UIImageResource = .mockRandom()
        let builder = UIImageViewWireframesBuilder(
            wireframeID: .mockAny(),
            imageWireframeID: .mockAny(),
            attributes: .mockAny(),
            contentFrame: .mockAny(),
            imageResource: resource,
            imagePrivacyLevel: .maskNonBundledOnly
        )
        let snapshot: ViewTreeSnapshot = .mockWith(
            context: .mockRandom(),
            nodes: [
                Node(viewAttributes: .mockAny(), wireframesBuilder: builder)
            ]
        )
        let resourceProcessor = ResourceProcessorSpy()
        let core = PassthroughCoreMock()
        let srContextPublisher = SRContextPublisher(core: core)
        let processor = SnapshotProcessor(
            queue: NoQueue(),
            recordWriter: recordWriter,
            resourceProcessor: resourceProcessor,
            srContextPublisher: srContextPublisher,
            telemetry: TelemetryMock()
        )

        processor.process(viewTreeSnapshot: snapshot, touchSnapshot: nil)

        let processedResource = try XCTUnwrap(resourceProcessor.processedResources.first?.resources.first)
        XCTAssertEqual(processedResource.calculateIdentifier(), resource.calculateIdentifier())
        XCTAssertEqual(processedResource.calculateData(), resource.calculateData())
        XCTAssertEqual(resourceProcessor.processedResources.first?.context, EnrichedResource.Context(snapshot.context.applicationID))
    }

    // MARK: - Processing `TouchSnapshots`

    func testWhenProcessingTouchSnapshot_itWritesRecordsThatContinueCurrentSegment() throws {
        let earliestTouchTime = Date()
        let snapshotTime = earliestTouchTime.addingTimeInterval(5)
        let numberOfTouches = 10
        let rum: RUMCoreContext = .mockWith(serverTimeOffset: 0)

        // Given
        let core = PassthroughCoreMock()
        let srContextPublisher = SRContextPublisher(core: core)
        let processor = SnapshotProcessor(
            queue: NoQueue(),
            recordWriter: recordWriter,
            resourceProcessor: ResourceProcessorSpy(),
            srContextPublisher: srContextPublisher,
            telemetry: TelemetryMock()
        )

        // When
        let touchSnapshot = generateTouchSnapshot(startAt: earliestTouchTime, endAt: snapshotTime, numberOfTouches: numberOfTouches)
        processor.process(viewTreeSnapshot: .mockWith(date: snapshotTime, context: .mockWith(rumContext: rum)), touchSnapshot: touchSnapshot)

        // Then
        XCTAssertEqual(recordWriter.records.count, 1)

        let enrichedRecord = try XCTUnwrap(recordWriter.records.first)
        XCTAssertEqual(enrichedRecord.applicationID, rum.applicationID)
        XCTAssertEqual(enrichedRecord.sessionID, rum.sessionID)
        XCTAssertEqual(enrichedRecord.viewID, rum.viewID)

        XCTAssertEqual(enrichedRecord.records.count, 13)
        XCTAssertTrue(
            enrichedRecord.records[0].isMetaRecord &&
            enrichedRecord.records[1].isFocusRecord &&
            enrichedRecord.records[2].isFullSnapshotRecord,
            "Segment must start with 'meta' → 'focus' → 'full snapshot' records"
        )

        try enrichedRecord.records[3..<13].forEach { record in
            let pointerInteractionData = try XCTUnwrap(
                record.incrementalSnapshot?.pointerInteractionData,
                "Touch information must be send in 'incremental snapshot'"
            )
            XCTAssertEqual(pointerInteractionData.pointerType, .touch)
            XCTAssertGreaterThanOrEqual(record.timestamp, earliestTouchTime.timeIntervalSince1970.dd.toInt64Milliseconds)
            XCTAssertLessThanOrEqual(record.timestamp, snapshotTime.timeIntervalSince1970.dd.toInt64Milliseconds)
        }

        XCTAssertEqual(core.recordsCountByViewID, ["abc": 13])
    }

    func testWhenRUMContextTimeOffsetChangesInSucceedingViewTreeSnapshots_itWritesRecordsThatContinueCurrentSegment() {
        let time = Date()
        let rum1: RUMCoreContext = .mockWith(serverTimeOffset: 123)
        let rum2: RUMCoreContext = .mockWith(serverTimeOffset: 456)

        // Given
        let core = PassthroughCoreMock()
        let srContextPublisher = SRContextPublisher(core: core)
        let processor = SnapshotProcessor(
            queue: NoQueue(),
            recordWriter: recordWriter,
            resourceProcessor: ResourceProcessorSpy(),
            srContextPublisher: srContextPublisher,
            telemetry: TelemetryMock()
        )

        let viewTree = generateSimpleViewTree()

        // When
        let snapshot1 = generateViewTreeSnapshot(for: viewTree, date: time, rumContext: rum1)
        let snapshot2 = generateViewTreeSnapshot(for: morphed(viewTree: viewTree), date: time.addingTimeInterval(1), rumContext: rum2)

        processor.process(viewTreeSnapshot: snapshot1, touchSnapshot: nil)
        processor.process(viewTreeSnapshot: snapshot2, touchSnapshot: nil)

        // Then
        let enrichedRecords = recordWriter.records
        XCTAssertEqual(recordWriter.records.count, 2)

        XCTAssertEqual(enrichedRecords[0].records.count, 3, "Segment must start with 'meta' → 'focus' → 'full snapshot' records")
        XCTAssertTrue(enrichedRecords[0].records[0].isMetaRecord)
        XCTAssertTrue(enrichedRecords[0].records[1].isFocusRecord)
        XCTAssertTrue(enrichedRecords[0].records[2].isFullSnapshotRecord)

        XCTAssertEqual(enrichedRecords[1].records.count, 1, "It should follow with 'incremental snapshot' record")
        XCTAssertTrue(enrichedRecords[1].records[0].isIncrementalSnapshotRecord)

        zip(enrichedRecords, [rum1, rum2]).forEach { enrichedRecord, expectedRUM in
            XCTAssertEqual(enrichedRecord.applicationID, expectedRUM.applicationID)
            XCTAssertEqual(enrichedRecord.sessionID, expectedRUM.sessionID)
            XCTAssertEqual(enrichedRecord.viewID, expectedRUM.viewID)
        }

        XCTAssertEqual(core.recordsCountByViewID, ["abc": 4])
    }

    func testViewRetentionInBackgroundProcessing() {
        weak var weakView: UIView?

        autoreleasepool {
            let view = UIView()
            weakView = view
            view.dd.sessionReplayPrivacyOverrides.imagePrivacy = .maskAll

            let time = Date()
            let rum: RUMCoreContext = .mockWith(serverTimeOffset: 0)

            // Given
            let core = PassthroughCoreMock()
            let srContextPublisher = SRContextPublisher(core: core)
            let processor = SnapshotProcessor(
                queue: NoQueue(),
                recordWriter: recordWriter,
                resourceProcessor: ResourceProcessorSpy(),
                srContextPublisher: srContextPublisher,
                telemetry: TelemetryMock()
            )

            // When
            let snapshot = generateViewTreeSnapshot(for: view, date: time, rumContext: rum)
            processor.process(viewTreeSnapshot: snapshot, touchSnapshot: nil)

            // Then
            XCTAssertEqual(recordWriter.records.count, 1)

            // View should still exist here
            XCTAssertNotNil(weakView)
        }

        // View should be deallocated even though snapshot was processed in background
        XCTAssertNil(weakView)
    }

    // MARK: - `ViewTreeSnapshot` generation

    private let snapshotBuilder = ViewTreeSnapshotBuilder(additionalNodeRecorders: [], featureFlags: .allEnabled)

    // MARK: - FLASHCAT FORK - replay withheld until the session errors

    private func makeProcessor(core: PassthroughCoreMock, telemetry: Telemetry = TelemetryMock()) -> SnapshotProcessor {
        SnapshotProcessor(
            queue: NoQueue(),
            recordWriter: recordWriter,
            resourceProcessor: ResourceProcessorSpy(),
            srContextPublisher: SRContextPublisher(core: core),
            telemetry: telemetry
        )
    }

    func testAWithheldReplayWritesNothing_butCountsItsRecords() {
        let core = PassthroughCoreMock()
        let processor = makeProcessor(core: core)
        let rum: RUMCoreContext = .mockWith(viewID: "v1", serverTimeOffset: 0)
        let viewTree = generateSimpleViewTree()
        let start = Date()

        processor.process(viewTreeSnapshot: generateViewTreeSnapshot(for: viewTree, date: start, rumContext: rum, replayHold: .withheld), touchSnapshot: nil)
        processor.process(viewTreeSnapshot: generateViewTreeSnapshot(for: viewTree, date: start.addingTimeInterval(1), rumContext: rum, replayHold: .withheld), touchSnapshot: nil)

        XCTAssertTrue(recordWriter.records.isEmpty)
        XCTAssertEqual(core.recordsCountByViewID?["v1"], 3, "counted as recorded, so a release can claim them")
    }

    func testWhenTheSessionReleasesTheReplay_theWithheldSegmentIsWrittenFirst_inOrder() throws {
        let telemetry = TelemetryMock()
        let core = PassthroughCoreMock()
        let processor = makeProcessor(core: core, telemetry: telemetry)
        let rum: RUMCoreContext = .mockWith(viewID: "v1", serverTimeOffset: 0)
        let start = Date()

        processor.process(viewTreeSnapshot: generateViewTreeSnapshot(for: generateSimpleViewTree(), date: start, rumContext: rum, replayHold: .withheld), touchSnapshot: nil)
        processor.process(viewTreeSnapshot: generateViewTreeSnapshot(for: generateSimpleViewTree(), date: start.addingTimeInterval(1), rumContext: rum, replayHold: .withheld), touchSnapshot: nil)
        processor.process(viewTreeSnapshot: generateViewTreeSnapshot(for: generateSimpleViewTree(), date: start.addingTimeInterval(2), rumContext: rum, replayHold: .none), touchSnapshot: nil)

        XCTAssertEqual(recordWriter.records.count, 3)
        let first = try XCTUnwrap(recordWriter.records.first)
        XCTAssertTrue(first.records[0].isMetaRecord, "the released segment plays on its own: it starts with a full snapshot")
        XCTAssertTrue(first.records[2].isFullSnapshotRecord)
        XCTAssertFalse(recordWriter.records[2].records.contains { $0.isFullSnapshotRecord }, "and the replay simply carries on")
        XCTAssertTrue(telemetry.messages.contains { message in
            guard case let .debug(_, text, _) = message else {
                return false
            }
            return text == "Error session replay released"
        })
    }

    func testWhenTheViewChangesWhileWithheld_theSegmentIsThrownAway_andItsCountGivenBack() {
        let core = PassthroughCoreMock()
        let processor = makeProcessor(core: core)
        let start = Date()

        processor.process(viewTreeSnapshot: generateViewTreeSnapshot(for: generateSimpleViewTree(), date: start, rumContext: .mockWith(viewID: "v1", serverTimeOffset: 0), replayHold: .withheld), touchSnapshot: nil)
        processor.process(viewTreeSnapshot: generateViewTreeSnapshot(for: generateSimpleViewTree(), date: start.addingTimeInterval(1), rumContext: .mockWith(viewID: "v2", serverTimeOffset: 0), replayHold: .withheld), touchSnapshot: nil)
        processor.process(viewTreeSnapshot: generateViewTreeSnapshot(for: generateSimpleViewTree(), date: start.addingTimeInterval(2), rumContext: .mockWith(viewID: "v2", serverTimeOffset: 0), replayHold: .none), touchSnapshot: nil)

        XCTAssertNil(core.recordsCountByViewID?["v1"], "no view claims a replay that was never uploaded")
        XCTAssertEqual(recordWriter.records.map { $0.viewID }, ["v2", "v2"])
    }

    func testWhenAWithheldSegmentOutgrowsTheWindow_itRestartsFromAFullSnapshot() throws {
        let core = PassthroughCoreMock()
        let processor = makeProcessor(core: core)
        let rum: RUMCoreContext = .mockWith(viewID: "v1", serverTimeOffset: 0)
        let viewTree = generateSimpleViewTree()
        let start = Date()

        processor.process(viewTreeSnapshot: generateViewTreeSnapshot(for: viewTree, date: start, rumContext: rum, replayHold: .withheld), touchSnapshot: nil)
        processor.process(viewTreeSnapshot: generateViewTreeSnapshot(for: viewTree, date: start.addingTimeInterval(SnapshotProcessor.withheldReplayDuration + 1), rumContext: rum, replayHold: .withheld), touchSnapshot: nil)
        processor.process(viewTreeSnapshot: generateViewTreeSnapshot(for: viewTree, date: start.addingTimeInterval(SnapshotProcessor.withheldReplayDuration + 2), rumContext: rum, replayHold: .none), touchSnapshot: nil)

        let released = try XCTUnwrap(recordWriter.records.first)
        XCTAssertTrue(released.records[0].isMetaRecord)
        XCTAssertTrue(released.records[2].isFullSnapshotRecord, "incremental records cannot follow a dropped history")
        XCTAssertEqual(core.recordsCountByViewID?["v1"], 3 + Int64(recordWriter.records.dropFirst().reduce(0) { $0 + $1.records.count }))
    }

    private func imageSnapshot(resource: UIImageResource, sessionID: String, viewID: String, date: Date, replayHold: Recorder.ReplayHold) -> ViewTreeSnapshot {
        let builder = UIImageViewWireframesBuilder(
            wireframeID: .mockAny(),
            imageWireframeID: .mockAny(),
            attributes: .mockAny(),
            contentFrame: .mockAny(),
            imageResource: resource,
            imagePrivacyLevel: .maskNonBundledOnly
        )
        return .mockWith(
            context: .init(
                textAndInputPrivacy: .maskAll,
                imagePrivacy: .maskNonBundledOnly,
                touchPrivacy: .hide,
                rumContext: .mockWith(sessionID: sessionID, viewID: viewID, serverTimeOffset: 0),
                date: date,
                replayHold: replayHold
            ),
            nodes: [Node(viewAttributes: .mockAny(), wireframesBuilder: builder)]
        )
    }

    func testTheResourcesOfAWithheldReplay_waitForItsRelease() throws {
        let resource: UIImageResource = .mockRandom()
        let resourceProcessor = ResourceProcessorSpy()
        let processor = SnapshotProcessor(
            queue: NoQueue(),
            recordWriter: recordWriter,
            resourceProcessor: resourceProcessor,
            srContextPublisher: SRContextPublisher(core: PassthroughCoreMock()),
            telemetry: TelemetryMock()
        )
        let start = Date()

        processor.process(viewTreeSnapshot: imageSnapshot(resource: resource, sessionID: "s1", viewID: "v1", date: start, replayHold: .withheld), touchSnapshot: nil)
        XCTAssertTrue(resourceProcessor.resources.isEmpty, "an image of a replay that may never be uploaded is not uploaded")

        processor.process(viewTreeSnapshot: imageSnapshot(resource: resource, sessionID: "s1", viewID: "v1", date: start.addingTimeInterval(1), replayHold: .none), touchSnapshot: nil)
        let released = try XCTUnwrap(resourceProcessor.processedResources.first?.resources.first)
        XCTAssertEqual(released.calculateIdentifier(), resource.calculateIdentifier(), "handed over with the segment it belongs to")
    }

    func testTheResourcesOfAThrownAwayReplay_areNeverProcessed() {
        let resourceProcessor = ResourceProcessorSpy()
        let processor = SnapshotProcessor(
            queue: NoQueue(),
            recordWriter: recordWriter,
            resourceProcessor: resourceProcessor,
            srContextPublisher: SRContextPublisher(core: PassthroughCoreMock()),
            telemetry: TelemetryMock()
        )
        let start = Date()

        processor.process(viewTreeSnapshot: imageSnapshot(resource: .mockRandom(), sessionID: "s1", viewID: "v1", date: start, replayHold: .withheld), touchSnapshot: nil)
        processor.process(viewTreeSnapshot: generateViewTreeSnapshot(for: generateSimpleViewTree(), date: start.addingTimeInterval(1), rumContext: .mockWith(sessionID: "s2", viewID: "v2", serverTimeOffset: 0)), touchSnapshot: nil)

        XCTAssertTrue(resourceProcessor.resources.isEmpty)
    }

    func testAWithheldSegmentOverItsResourceBudget_restartsFromAFullSnapshot() throws {
        let core = PassthroughCoreMock()
        let resourceProcessor = ResourceProcessorSpy()
        let processor = SnapshotProcessor(
            queue: NoQueue(),
            recordWriter: recordWriter,
            resourceProcessor: resourceProcessor,
            srContextPublisher: SRContextPublisher(core: core),
            telemetry: TelemetryMock()
        )
        let start = Date()
        let snapshots = SnapshotProcessor.withheldReplayResourcesLimit + 1
        for index in 0..<snapshots {
            processor.process(viewTreeSnapshot: imageSnapshot(resource: .mockRandom(), sessionID: "s1", viewID: "v1", date: start.addingTimeInterval(Double(index) * 0.1), replayHold: .withheld), touchSnapshot: nil)
        }
        processor.process(viewTreeSnapshot: imageSnapshot(resource: .mockRandom(), sessionID: "s1", viewID: "v1", date: start.addingTimeInterval(20), replayHold: .withheld), touchSnapshot: nil)
        processor.process(viewTreeSnapshot: imageSnapshot(resource: .mockRandom(), sessionID: "s1", viewID: "v1", date: start.addingTimeInterval(21), replayHold: .none), touchSnapshot: nil)

        let released = try XCTUnwrap(recordWriter.records.first)
        XCTAssertTrue(released.records.contains { $0.isFullSnapshotRecord }, "the restarted segment plays on its own")
        XCTAssertLessThanOrEqual(recordWriter.records.count, 2, "only what was recorded since the restart is released")
        XCTAssertEqual(resourceProcessor.resources.count, 2)
    }

    func testAWithheldSegment_countsAResourceOnce_howeverManySnapshotsShowIt() throws {
        // The builder reports every image's resource on every snapshot, ten times a second. Counted
        // per snapshot, a screen with a few images would spend the resource budget within seconds
        // and the withheld segment would be restarted over and over, keeping nothing before the error.
        let resource: UIImageResource = .mockRandom()
        let resourceProcessor = ResourceProcessorSpy()
        let telemetry = TelemetryMock()
        let processor = SnapshotProcessor(
            queue: NoQueue(),
            recordWriter: recordWriter,
            resourceProcessor: resourceProcessor,
            srContextPublisher: SRContextPublisher(core: PassthroughCoreMock()),
            telemetry: telemetry
        )
        let start = Date()
        let snapshots = SnapshotProcessor.withheldReplayResourcesLimit + 50
        for index in 0..<snapshots {
            processor.process(viewTreeSnapshot: imageSnapshot(resource: resource, sessionID: "s1", viewID: "v1", date: start.addingTimeInterval(Double(index) * 0.1), replayHold: .withheld), touchSnapshot: nil)
        }
        processor.process(viewTreeSnapshot: imageSnapshot(resource: resource, sessionID: "s1", viewID: "v1", date: start.addingTimeInterval(Double(snapshots) * 0.1), replayHold: .none), touchSnapshot: nil)

        let release = telemetry.messages.compactMap { message -> [String: Encodable]? in
            guard case let .debug(_, text, attributes) = message, text == "Error session replay released" else {
                return nil
            }
            return attributes
        }
        XCTAssertEqual(release.first?["segment.dropped_before"] as? Int, 0, "the segment was never restarted")
        XCTAssertEqual(resourceProcessor.processedResources.first?.resources.count, 1, "one image, handed over once with the segment")
    }

    func testWhileTheReleaseIsPending_aViewChangeKeepsTheSegment_andTheNewViewIsHeldBehindIt() throws {
        // An error is usually followed by a screen change - the app showing it. The release
        // is on its way, so the segment of the screen the error happened on must survive it.
        let core = PassthroughCoreMock()
        let processor = makeProcessor(core: core)
        let start = Date()

        processor.process(viewTreeSnapshot: generateViewTreeSnapshot(for: generateSimpleViewTree(), date: start, rumContext: .mockWith(viewID: "v1", serverTimeOffset: 0), replayHold: .withheld), touchSnapshot: nil)
        processor.process(viewTreeSnapshot: generateViewTreeSnapshot(for: generateSimpleViewTree(), date: start.addingTimeInterval(1), rumContext: .mockWith(viewID: "v2", serverTimeOffset: 0), replayHold: .releasePending), touchSnapshot: nil)
        XCTAssertTrue(recordWriter.records.isEmpty, "nothing goes out before the events do")
        XCTAssertEqual(core.recordsCountByViewID?["v1"], 3, "the first view still holds its records")

        processor.process(viewTreeSnapshot: generateViewTreeSnapshot(for: generateSimpleViewTree(), date: start.addingTimeInterval(2), rumContext: .mockWith(viewID: "v2", serverTimeOffset: 0), replayHold: .none), touchSnapshot: nil)

        XCTAssertEqual(recordWriter.records.map { $0.viewID }, ["v1", "v2", "v2"])
        XCTAssertTrue(try XCTUnwrap(recordWriter.records[1].records.first?.isMetaRecord), "the new view starts its own segment")
    }

    func testControl_withoutAReleasePending_aViewChangeThrowsTheSegmentAway() {
        let core = PassthroughCoreMock()
        let processor = makeProcessor(core: core)
        let start = Date()

        processor.process(viewTreeSnapshot: generateViewTreeSnapshot(for: generateSimpleViewTree(), date: start, rumContext: .mockWith(viewID: "v1", serverTimeOffset: 0), replayHold: .withheld), touchSnapshot: nil)
        processor.process(viewTreeSnapshot: generateViewTreeSnapshot(for: generateSimpleViewTree(), date: start.addingTimeInterval(1), rumContext: .mockWith(viewID: "v2", serverTimeOffset: 0), replayHold: .withheld), touchSnapshot: nil)

        XCTAssertNil(core.recordsCountByViewID?["v1"])
    }

    func testWhatWasRecordedWithoutConsent_isThrownAway_andRecordingRestartsFromAFullSnapshot() throws {
        let core = PassthroughCoreMock()
        let processor = makeProcessor(core: core)
        let rum: RUMCoreContext = .mockWith(viewID: "v1", serverTimeOffset: 0)
        let viewTree = generateSimpleViewTree()
        let start = Date()

        processor.process(viewTreeSnapshot: generateViewTreeSnapshot(for: viewTree, date: start, rumContext: rum, replayHold: .withheld, trackingConsent: .granted), touchSnapshot: nil)
        XCTAssertEqual(core.recordsCountByViewID?["v1"], 3)

        processor.process(viewTreeSnapshot: generateViewTreeSnapshot(for: viewTree, date: start.addingTimeInterval(1), rumContext: rum, replayHold: .withheld, trackingConsent: .notGranted), touchSnapshot: nil)
        XCTAssertNil(core.recordsCountByViewID?["v1"], "what was held is given back")

        processor.process(viewTreeSnapshot: generateViewTreeSnapshot(for: viewTree, date: start.addingTimeInterval(2), rumContext: rum, replayHold: .withheld, trackingConsent: .granted), touchSnapshot: nil)
        processor.process(viewTreeSnapshot: generateViewTreeSnapshot(for: viewTree, date: start.addingTimeInterval(3), rumContext: rum, replayHold: .none, trackingConsent: .granted), touchSnapshot: nil)

        // The held full snapshot; the releasing snapshot of the unchanged tree adds no record.
        XCTAssertEqual(recordWriter.records.count, 1, "only what was recorded once consent returned")
        let released = try XCTUnwrap(recordWriter.records.first)
        XCTAssertTrue(released.records[0].isMetaRecord, "it starts over from a full snapshot")
        XCTAssertTrue(released.records[2].isFullSnapshotRecord)
    }

    func testDiscardingTheWithheldRecords_throwsThemAway_andRecordingRestartsFromAFullSnapshot() throws {
        let core = PassthroughCoreMock()
        let processor = makeProcessor(core: core)
        let rum: RUMCoreContext = .mockWith(viewID: "v1", serverTimeOffset: 0)
        let viewTree = generateSimpleViewTree()
        let start = Date()
        processor.process(viewTreeSnapshot: generateViewTreeSnapshot(for: viewTree, date: start, rumContext: rum, replayHold: .withheld), touchSnapshot: nil)
        XCTAssertEqual(core.recordsCountByViewID?["v1"], 3)

        processor.discardWithheldRecords()

        XCTAssertNil(core.recordsCountByViewID?["v1"], "what was held is given back")
        processor.process(viewTreeSnapshot: generateViewTreeSnapshot(for: viewTree, date: start.addingTimeInterval(1), rumContext: rum, replayHold: .withheld), touchSnapshot: nil)
        processor.process(viewTreeSnapshot: generateViewTreeSnapshot(for: viewTree, date: start.addingTimeInterval(2), rumContext: rum, replayHold: .none), touchSnapshot: nil)
        let released = try XCTUnwrap(recordWriter.records.first)
        XCTAssertEqual(recordWriter.records.count, 1)
        XCTAssertTrue(released.records[0].isMetaRecord, "it starts over from a full snapshot")
        XCTAssertTrue(released.records[2].isFullSnapshotRecord)
    }

    func testControl_aReplayThatIsNotWithheld_isWrittenWhateverTheConsent() {
        // The writer of the moment decides for it, as it always did.
        let processor = makeProcessor(core: PassthroughCoreMock())
        let start = Date()

        processor.process(viewTreeSnapshot: generateViewTreeSnapshot(for: generateSimpleViewTree(), date: start, rumContext: .mockWith(viewID: "v1", serverTimeOffset: 0), replayHold: .none, trackingConsent: .notGranted), touchSnapshot: nil)

        XCTAssertEqual(recordWriter.records.count, 1)
    }

    func testAWithheldSegmentOverItsResourceByteBudget_restartsFromAFullSnapshot() throws {
        // Distinct images keep their decoded bitmaps alive while held; a feed shows many in a
        // minute, so they are budgeted in bytes, not only in number.
        let core = PassthroughCoreMock()
        let resourceProcessor = ResourceProcessorSpy()
        let processor = SnapshotProcessor(
            queue: NoQueue(),
            recordWriter: recordWriter,
            resourceProcessor: resourceProcessor,
            srContextPublisher: SRContextPublisher(core: core),
            telemetry: TelemetryMock()
        )
        var distinct = 0
        func bigImage() -> UIImageResource {
            // One bitmap, told apart by its tint: the identifier covers the tint, and a distinct
            // tint is cheaper and surer than a distinct bitmap.
            let size = CGSize(width: 1_024, height: 1_024) // 4 MiB a bitmap at scale 1
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.red.setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
            distinct += 1
            return UIImageResource(image: image, tintColor: UIColor(white: CGFloat(distinct) / 100, alpha: 1))
        }
        XCTAssertEqual(bigImage().estimatedRetainedBytes, 4 * 1_024 * 1_024)
        let start = Date()
        let images = SnapshotProcessor.withheldReplayResourcesBytesLimit / (4 * 1_024 * 1_024) + 1
        for index in 0..<images {
            processor.process(viewTreeSnapshot: imageSnapshot(resource: bigImage(), sessionID: "s1", viewID: "v1", date: start.addingTimeInterval(Double(index) * 0.1), replayHold: .withheld), touchSnapshot: nil)
        }
        processor.process(viewTreeSnapshot: imageSnapshot(resource: bigImage(), sessionID: "s1", viewID: "v1", date: start.addingTimeInterval(20), replayHold: .withheld), touchSnapshot: nil)
        processor.process(viewTreeSnapshot: imageSnapshot(resource: bigImage(), sessionID: "s1", viewID: "v1", date: start.addingTimeInterval(21), replayHold: .none), touchSnapshot: nil)

        let released = try XCTUnwrap(recordWriter.records.first)
        XCTAssertTrue(released.records.contains { $0.isFullSnapshotRecord }, "the restarted segment plays on its own")
        XCTAssertEqual(resourceProcessor.resources.count, 2, "only the images recorded since the restart")
    }

    func testAWithheldReplayOfASessionThatEndedWithoutAnError_isThrownAway() {
        let core = PassthroughCoreMock()
        let processor = makeProcessor(core: core)
        let start = Date()

        processor.process(viewTreeSnapshot: generateViewTreeSnapshot(for: generateSimpleViewTree(), date: start, rumContext: .mockWith(sessionID: "s1", viewID: "v1", serverTimeOffset: 0), replayHold: .withheld), touchSnapshot: nil)
        processor.process(viewTreeSnapshot: generateViewTreeSnapshot(for: generateSimpleViewTree(), date: start.addingTimeInterval(1), rumContext: .mockWith(sessionID: "s2", viewID: "v2", serverTimeOffset: 0)), touchSnapshot: nil)

        XCTAssertEqual(recordWriter.records.map { $0.sessionID }, ["s2"])
    }

    private func generateViewTreeSnapshot(
        for viewTree: UIView,
        date: Date,
        rumContext: RUMCoreContext,
        replayHold: Recorder.ReplayHold = .none,
        trackingConsent: TrackingConsent = .granted
    ) -> ViewTreeSnapshot {
        snapshotBuilder.createSnapshot(
            of: viewTree,
            with: .init(
                textAndInputPrivacy: .mockRandom(),
                imagePrivacy: .mockRandom(),
                touchPrivacy: .mockRandom(),
                rumContext: rumContext,
                date: date,
                replayHold: replayHold,
                trackingConsent: trackingConsent
            )
        )
    }

    private func generateSimpleViewTree() -> UIView {
        let root = UIView.mock(withFixture: .visible(.someAppearance))
        root.frame = .mockRandom(
            minX: 0,
            maxX: 0,
            minY: 0,
            maxY: 0,
            minWidth: 1_000,
            maxWidth: 2_000,
            minHeight: 1_000,
            maxHeight: 2_000
        )
        let child = UIView.mock(withFixture: .visible(.someAppearance))
        child.frame = .mockRandom(
            minX: 0,
            maxX: 100,
            minY: 0,
            maxY: 100,
            minWidth: 100,
            maxWidth: 200,
            minHeight: 100,
            maxHeight: 200
        )
        root.addSubview(child)
        return root
    }

    /// Alters the state of given `viewTree` a little bit so its next snapshot will include some changes.
    /// Returns altered `viewTree` for convenience (although mutation is applied in place through reference type).
    private func morphed(viewTree: UIView) -> UIView {
        var childFrame = viewTree.subviews.first?.frame ?? .zero
        childFrame = childFrame.applying(.init(translationX: .mockRandom(min: 1, max: 10), y: .mockRandom(min: 1, max: 10)))
        viewTree.subviews.first?.frame = childFrame
        return viewTree
    }

    // MARK: - `TouchSnapshot` generation

    private func generateTouchSnapshot(startAt startTime: Date, endAt endTime: Date, numberOfTouches: Int) -> TouchSnapshot {
        let dt = endTime.timeIntervalSince(startTime)
        return TouchSnapshot(
            date: startTime,
            touches: (0..<numberOfTouches).map { index in
                    .init(
                        id: .mockRandom(min: 0, max: TouchIdentifier(numberOfTouches)),
                        phase: [.down, .move, .up].randomElement()!,
                        date: startTime.addingTimeInterval(Double(index) * (dt / Double(numberOfTouches))),
                        position: .mockRandom(),
                        touchOverride: nil
                    )
            }
        )
    }
}

fileprivate extension PassthroughCoreMock {
    var recordsCountByViewID: [String: Int64]? {
        context.additionalContext(
            ofType: SessionReplayCoreContext.RecordsCount.self
        )?.value
    }
}
#endif
