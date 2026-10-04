/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import XCTest
import DatadogInternal
@testable import DatadogRUM
@testable import TestUtilities

class RUMWithheldEventBufferTests: XCTestCase {
    private typealias Constants = RUMWithheldEventBuffer.Constants

    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let buffer = RUMWithheldEventBuffer()
    private let writer = FileWriterMock()

    // MARK: - Event fixtures

    /// Re-encodes an event with some of its JSON changed, so the fields the buffer reads (which
    /// the generated models keep immutable) can be set. Optional bulk is stripped, so the byte
    /// budget only binds where a test means it to.
    private func edit<T: Codable>(_ event: T, _ change: (inout [String: Any]) -> Void) -> T {
        let data = try! JSONEncoder().encode(event)
        var json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        ["account", "connectivity", "context", "device", "display", "os", "usr", "synthetics", "ci_test", "feature_flags", "container", "stream"]
            .forEach { json.removeValue(forKey: $0) }
        change(&json)
        return try! JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func setting(_ key: String, to value: Any, in object: String, of json: inout [String: Any]) {
        var nested = json[object] as! [String: Any]
        nested[key] = value
        json[object] = nested
    }

    private func view(_ id: String, date: Int64) -> RUMViewEvent {
        .mockRandomWith(viewID: id, date: date)
    }

    private func error(on viewID: String, message: String = "error") -> RUMErrorEvent {
        edit(RUMErrorEvent.mockRandom()) {
            setting("id", to: viewID, in: "view", of: &$0)
            setting("message", to: message, in: "error", of: &$0)
            setting("stack", to: NSNull(), in: "error", of: &$0)
            setting("binary_images", to: NSNull(), in: "error", of: &$0)
            setting("threads", to: NSNull(), in: "error", of: &$0)
            $0["context"] = NSNull()
        }
    }

    private func resource(on viewID: String, statusCode: Int64?) -> RUMResourceEvent {
        edit(RUMResourceEvent.mockRandom()) {
            setting("id", to: viewID, in: "view", of: &$0)
            setting("status_code", to: statusCode.map { $0 as Any } ?? NSNull(), in: "resource", of: &$0)
            $0["context"] = NSNull()
        }
    }

    private func longTask(on viewID: String) -> RUMLongTaskEvent {
        edit(RUMLongTaskEvent.mockRandom()) {
            setting("id", to: viewID, in: "view", of: &$0)
            $0["context"] = NSNull()
        }
    }

    /// As small as an action gets, so that the count limit binds before the byte budget does.
    private func action(on viewID: String) -> RUMActionEvent {
        let json: [String: Any] = [
            "_dd": [String: Any](),
            "application": ["id": "a"],
            "date": 0,
            "session": ["id": "s", "type": "user"],
            "type": "action",
            "view": ["id": viewID, "url": ""],
            "action": ["type": "custom"]
        ]
        return try! JSONDecoder().decode(RUMActionEvent.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @discardableResult
    private func hold<T: Encodable>(_ event: T, at time: Date, completion: @escaping CompletionHandler = {}) -> Bool {
        buffer.hold(value: event, metadata: nil as Data?, completion: completion, now: time)
    }

    private func release(at time: Date) -> RUMWithheldEventBuffer.ReleaseSummary {
        buffer.release(to: writer, now: time)
    }

    // MARK: - Views

    func testItKeepsOnlyTheLatestUpdateOfEachView() {
        var superseded = false
        hold(view("v1", date: 1), at: start, completion: { superseded = true })
        let latest = view("v1", date: 1)
        hold(latest, at: start)

        _ = release(at: start)

        XCTAssertEqual(writer.events(ofType: RUMViewEvent.self).count, 1)
        XCTAssertEqual(writer.events(ofType: RUMViewEvent.self).first?.dd.documentVersion, latest.dd.documentVersion)
        XCTAssertTrue(superseded, "the completion of a superseded view update is not left hanging")
    }

    func testViewsDoNotCountAgainstTheEventBudget() {
        hold(view("v1", date: 1), at: start)
        (0..<Constants.eventsLimit).forEach { _ in hold(action(on: "v1"), at: start) }
        hold(view("v1", date: 1), at: start)

        let summary = release(at: start)

        XCTAssertEqual(summary.eventsCount, Constants.eventsLimit)
        XCTAssertEqual(summary.droppedCount, 0)
    }

    func testItNeverKeepsMoreThanTheViewLimit_butNeverDropsTheCurrentView() {
        // The current view is judged by start date, so the newest view arriving first stays the
        // current one while older views keep arriving - late updates, each with its own detail.
        hold(view("current", date: 10_000), at: start)
        for index in 0..<(Constants.viewsLimit + 5) {
            hold(action(on: "old-\(index)"), at: start)
            hold(view("old-\(index)", date: Int64(index)), at: start)
        }

        _ = release(at: start)

        let released = writer.events(ofType: RUMViewEvent.self).map { $0.view.id }
        XCTAssertEqual(released.count, Constants.viewsLimit)
        XCTAssertTrue(released.contains("current"))
        XCTAssertFalse(released.contains("old-0"), "the least recently updated view goes first")
    }

    func testALateUpdateOfAnEndedViewDoesNotMakeItCurrentAgain() {
        hold(view("old", date: 1), at: start)
        hold(view("new", date: 2), at: start)
        // A late update of the old view, with nothing hanging from either view.
        hold(view("old", date: 1), at: start.addingTimeInterval(1))

        _ = release(at: start.addingTimeInterval(1))

        let released = writer.events(ofType: RUMViewEvent.self).map { $0.view.id }
        XCTAssertEqual(released, ["new"], "the view in progress is the one kept as a container")
    }

    // MARK: - Window

    func testItOnlyKeepsTheLastMinute() {
        hold(view("v1", date: 1), at: start)
        hold(action(on: "v1"), at: start)
        hold(view("v2", date: 2), at: start.addingTimeInterval(30))
        hold(action(on: "v2"), at: start.addingTimeInterval(30))

        let summary = release(at: start.addingTimeInterval(Constants.duration + 10))

        XCTAssertEqual(summary.eventsCount, 1)
        XCTAssertEqual(writer.events(ofType: RUMActionEvent.self).count, 1)
        XCTAssertEqual(
            writer.events(ofType: RUMViewEvent.self).map { $0.view.id },
            ["v2"],
            "a view with nothing left in the window has nothing to contain"
        )
    }

    func testTheWindowFreezesWhenTheReleaseIsScheduled() {
        // A release timer that fires late must not prune the minute before the error.
        hold(view("v1", date: 1), at: start)
        hold(action(on: "v1"), at: start)
        hold(error(on: "v1"), at: start.addingTimeInterval(50))
        buffer.freezeWindow(at: start.addingTimeInterval(50))

        let summary = release(at: start.addingTimeInterval(50 + Constants.duration))

        XCTAssertEqual(summary.eventsCount, 2)
        XCTAssertEqual(writer.events(ofType: RUMActionEvent.self).count, 1)
    }

    // MARK: - Budget

    func testOverBudget_successfulRequestsAndLongTasksGoFirst_thenTheRest_andErrorsLast() {
        hold(view("v1", date: 1), at: start)
        hold(error(on: "v1", message: "first"), at: start)
        hold(resource(on: "v1", statusCode: 500), at: start)
        hold(resource(on: "v1", statusCode: 0), at: start)
        hold(longTask(on: "v1"), at: start)
        hold(resource(on: "v1", statusCode: 200), at: start)
        hold(resource(on: "v1", statusCode: nil), at: start)
        (0..<(Constants.eventsLimit - 6)).forEach { _ in hold(action(on: "v1"), at: start) }
        // At the limit now. Each of the next ones evicts one event.
        hold(action(on: "v1"), at: start)
        hold(action(on: "v1"), at: start)
        hold(action(on: "v1"), at: start)

        _ = release(at: start)

        XCTAssertEqual(writer.events(ofType: RUMLongTaskEvent.self).count, 0)
        XCTAssertEqual(
            writer.events(ofType: RUMResourceEvent.self).compactMap { $0.resource.statusCode }.sorted(),
            [0, 500],
            "a failed request explains the error; a successful one rarely does"
        )
        XCTAssertEqual(writer.events(ofType: RUMErrorEvent.self).count, 1)
    }

    func testWhenOnlyErrorsAreLeft_theNewestErrorGoes() {
        hold(view("v1", date: 1), at: start)
        hold(error(on: "v1", message: "first"), at: start)
        (0..<Constants.eventsLimit).forEach { hold(error(on: "v1", message: "storm \($0)"), at: start) }

        _ = release(at: start)

        let messages = writer.events(ofType: RUMErrorEvent.self).map { $0.error.message }
        XCTAssertLessThanOrEqual(messages.count, Constants.eventsLimit)
        XCTAssertEqual(messages.first, "first", "the error the session is about is never pushed out")
        XCTAssertTrue(messages.contains("storm 0"))
        XCTAssertFalse(messages.contains("storm \(Constants.eventsLimit - 1)"), "the newest error is the one to go")
    }

    func testOverByteBudget_itEvictsUntilItFits() {
        hold(view("v1", date: 1), at: start)
        let big = String(repeating: "x", count: Constants.bytesLimit / 4)
        (0..<5).forEach { _ in hold(error(on: "v1", message: big), at: start) }

        let summary = release(at: start)

        XCTAssertLessThanOrEqual(summary.bytes, Constants.bytesLimit)
        XCTAssertEqual(writer.events(ofType: RUMErrorEvent.self).count, 3)
    }

    func testAnEventLargerThanTheWholeBudgetIsDropped_butAnErrorIsHandedBack() {
        hold(view("v1", date: 1), at: start)
        hold(action(on: "v1"), at: start)
        let huge = String(repeating: "x", count: Constants.bytesLimit + 1)

        let heldAction = hold(edit(action(on: "v1")) { $0["context"] = ["big": huge] }, at: start)
        let heldError = hold(error(on: "v1", message: huge), at: start)

        XCTAssertTrue(heldAction)
        XCTAssertFalse(heldError, "an oversized error goes out on its own instead")
        let summary = release(at: start)
        XCTAssertEqual(summary.eventsCount, 1, "the history before them is untouched")
        XCTAssertEqual(summary.droppedCount, 1)
    }

    // MARK: - Release

    func testReleaseOrder_viewsByStartDate_thenErrors_thenTheRestOldestFirst() {
        hold(view("v1", date: 1), at: start)
        hold(action(on: "v1"), at: start)
        hold(view("v2", date: 2), at: start)
        hold(resource(on: "v2", statusCode: 200), at: start.addingTimeInterval(1))
        hold(error(on: "v2"), at: start.addingTimeInterval(2))
        hold(view("v1", date: 1), at: start.addingTimeInterval(2)) // a late update moves v1 last in arrival order

        _ = release(at: start.addingTimeInterval(2))

        let kinds: [String] = writer.events.map { event in
            switch event {
            case let view as RUMViewEvent: return "view:\(view.view.id)"
            case is RUMErrorEvent: return "error"
            case is RUMActionEvent: return "action"
            case is RUMResourceEvent: return "resource"
            default: return "other"
            }
        }
        XCTAssertEqual(kinds, ["view:v1", "view:v2", "error", "action", "resource"])
    }

    func testReleaseKeepsTheMetadataAndCompletionOfEachEvent() {
        var completions = 0
        buffer.hold(value: view("v1", date: 1), metadata: "view-meta", completion: { completions += 1 }, now: start)
        buffer.hold(value: action(on: "v1"), metadata: "action-meta", completion: { completions += 1 }, now: start)

        _ = release(at: start)

        XCTAssertEqual(writer.metadata(ofType: String.self), ["view-meta", "action-meta"])
        XCTAssertEqual(completions, 2)
    }

    func testAfterARelease_theBufferIsEmpty() {
        hold(view("v1", date: 1), at: start)
        hold(action(on: "v1"), at: start)
        buffer.freezeWindow(at: start)

        _ = release(at: start)

        XCTAssertNil(buffer.releaseScheduledAt)
        XCTAssertEqual(release(at: start), .init(viewsCount: 0, eventsCount: 0, droppedCount: 0, bytes: 0))
    }

    func testDiscardWritesNothing_andCompletesEverythingItHeld() {
        var completions = 0
        hold(view("v1", date: 1), at: start, completion: { completions += 1 })
        hold(action(on: "v1"), at: start, completion: { completions += 1 })

        buffer.discard()

        XCTAssertEqual(release(at: start).viewsCount, 0)
        XCTAssertTrue(writer.events.isEmpty)
        XCTAssertEqual(completions, 2)
    }

    // MARK: - Jitter

    func testReleaseDelayIsDeterministicAndWithinTheWindow() {
        let sessionID = UUID().uuidString.lowercased()
        let delay = RUMWithheldEventBuffer.releaseDelay(sessionID: sessionID)

        XCTAssertEqual(delay, RUMWithheldEventBuffer.releaseDelay(sessionID: sessionID))
        XCTAssertGreaterThanOrEqual(delay, 0)
        XCTAssertLessThan(delay, Constants.releaseMaxDelay)
    }

    func testReleaseDelaysSpreadOverTheWholeWindow() {
        // Session ids share their length and alphabet; a hash that merely sums them would bunch
        // every client into a few hundred milliseconds.
        let delays = (0..<1_000).map { _ in RUMWithheldEventBuffer.releaseDelay(sessionID: UUID().uuidString.lowercased()) }
        let buckets = Dictionary(grouping: delays) { Int($0 / 0.5) }

        XCTAssertEqual(buckets.count, 6, "every half second of the window gets releases")
        XCTAssertTrue(buckets.values.allSatisfy { $0.count > 100 }, "\(buckets.mapValues { $0.count })")
    }
}
