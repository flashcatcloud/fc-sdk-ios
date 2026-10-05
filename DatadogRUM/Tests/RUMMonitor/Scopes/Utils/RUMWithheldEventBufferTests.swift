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
    private func hold<E: RUMWithheldEvent>(_ event: E, at time: Date, completion: @escaping CompletionHandler = {}) -> Bool {
        buffer.hold(event: event, metadata: nil as Data?, completion: completion, now: time)
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

    func testAnErrorWhoseViewIsNotHeld_isStillReleased() {
        // An error assembled before any view event, or hanging from a view that was evicted, is
        // what releases the session: it must never be the thing left behind.
        hold(error(on: "never-seen"), at: start)
        hold(action(on: "never-seen"), at: start)

        let summary = release(at: start)

        XCTAssertEqual(writer.events(ofType: RUMErrorEvent.self).count, 1)
        XCTAssertEqual(writer.events(ofType: RUMActionEvent.self).count, 1)
        XCTAssertEqual(summary.eventsCount, 2)
        XCTAssertEqual(summary.viewsCount, 0)
    }

    func testReleaseKeepsTheMetadataAndCompletionOfEachEvent() {
        var completions = 0
        buffer.hold(event: view("v1", date: 1), metadata: "view-meta", completion: { completions += 1 }, now: start)
        buffer.hold(event: action(on: "v1"), metadata: "action-meta", completion: { completions += 1 }, now: start)

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

    func testEveryKindOfEventCanClaimTheReplay() {
        XCTAssertEqual(view("v1", date: 1).claimingReplay(records: 1).session.hasReplay, true)
        XCTAssertEqual(error(on: "v1").claimingReplay(records: 1).session.hasReplay, true)
        XCTAssertEqual(resource(on: "v1", statusCode: 200).claimingReplay(records: 1).session.hasReplay, true)
        XCTAssertEqual(longTask(on: "v1").claimingReplay(records: 1).session.hasReplay, true)
        XCTAssertEqual(RUMActionEvent.mockAny().claimingReplay(records: 1).session.hasReplay, true)
        XCTAssertEqual(RUMVitalAppLaunchEvent.mockRandom().claimingReplay(records: 1).session.hasReplay, true)
        XCTAssertEqual(RUMVitalDurationEvent.mockRandom().claimingReplay(records: 1).session.hasReplay, true)
        XCTAssertEqual(RUMVitalOperationStepEvent.mockRandom().claimingReplay(records: 1).session.hasReplay, true)
    }

    func testClaimingTheReplayChangesNothingElse_asTheIntakeWillSeeIt() throws {
        // The claim goes through the JSON form of the event, so every field of every kind of event
        // must reach the intake exactly as it would have - random attributes included, and a date
        // among them, which the intake's encoder writes as a string and a plain one as a number.
        func json<T: Encodable>(_ event: T) throws -> NSDictionary {
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.dd.default().encode(event)) as? NSDictionary)
        }
        func claimed(_ original: NSDictionary, records: Int64) -> NSDictionary {
            let copy = NSMutableDictionary(dictionary: original)
            let session = NSMutableDictionary(dictionary: copy["session"] as? NSDictionary ?? [:])
            session["has_replay"] = true
            copy["session"] = session
            if copy["type"] as? String == "view" {
                let dd = NSMutableDictionary(dictionary: copy["_dd"] as? NSDictionary ?? [:])
                let stats = NSMutableDictionary(dictionary: dd["replay_stats"] as? NSDictionary ?? [:])
                stats["records_count"] = records
                dd["replay_stats"] = stats
                copy["_dd"] = dd
            }
            return copy
        }
        struct Nested: Encodable {
            let n = 1.5
            let s = "x"
        }
        let attributes = RUMEventAttributes(contextInfo: ["when": Date(timeIntervalSince1970: 1_700_000_000), "nested": Nested()])
        for _ in 0..<20 {
            var view = RUMViewEvent.mockRandom()
            view.context = attributes
            XCTAssertEqual(try json(view.claimingReplay(records: 7)), claimed(try json(view), records: 7))
            var error = RUMErrorEvent.mockRandom()
            error.context = attributes
            XCTAssertEqual(try json(error.claimingReplay(records: 7)), claimed(try json(error), records: 7))
            let resource = RUMResourceEvent.mockRandom()
            XCTAssertEqual(try json(resource.claimingReplay(records: 7)), claimed(try json(resource), records: 7))
            let action = RUMActionEvent.mockAny()
            XCTAssertEqual(try json(action.claimingReplay(records: 7)), claimed(try json(action), records: 7))
            let longTask = RUMLongTaskEvent.mockRandom()
            XCTAssertEqual(try json(longTask.claimingReplay(records: 7)), claimed(try json(longTask), records: 7))
            let appLaunch = RUMVitalAppLaunchEvent.mockRandom()
            XCTAssertEqual(try json(appLaunch.claimingReplay(records: 7)), claimed(try json(appLaunch), records: 7))
            let duration = RUMVitalDurationEvent.mockRandom()
            XCTAssertEqual(try json(duration.claimingReplay(records: 7)), claimed(try json(duration), records: 7))
            let step = RUMVitalOperationStepEvent.mockRandom()
            XCTAssertEqual(try json(step.claimingReplay(records: 7)), claimed(try json(step), records: 7))
        }
    }

    func testReleasedEventsClaimTheReplayOnlyWhereTheirViewKeptRecords() {
        hold(view("v1", date: 1), at: start)
        hold(action(on: "v1"), at: start)
        hold(view("v2", date: 2), at: start)
        hold(error(on: "v2"), at: start)

        _ = buffer.release(to: writer, now: start, recordsCountByViewID: ["v1": 3, "v2": 0])

        XCTAssertEqual(writer.events(ofType: RUMViewEvent.self).map { $0.session.hasReplay == true }, [true, false])
        XCTAssertEqual(
            writer.events(ofType: RUMViewEvent.self).map { $0.dd.replayStats?.recordsCount },
            [3, nil],
            "a view that ended while the replay was withheld gets no later update to carry the count"
        )
        XCTAssertEqual(writer.events(ofType: RUMActionEvent.self).first?.session.hasReplay, true)
        XCTAssertNotEqual(writer.events(ofType: RUMErrorEvent.self).first?.session.hasReplay, true)
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
