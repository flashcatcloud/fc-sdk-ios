/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation
import DatadogInternal

/// FLASHCAT FORK - the events of a session kept only in case it reports an error (`sessionOnError`).
///
/// Events reach it fully assembled, after the event mapper, and nothing in it is uploaded: if the
/// session ends without an error the buffer is thrown away. When the session reports one, the
/// buffer is written out in one go and the session carries on as an ordinary collected one.
///
/// It is owned by the session scope, which is also the only producer of the events it holds: when
/// the scope goes away, so does every child scope that could still have produced an event for that
/// session, so no event of a discarded session can arrive afterwards.
internal final class RUMWithheldEventBuffer {
    enum Constants {
        /// How much history the buffer may span: an error session shows the minute leading up to
        /// the error.
        static let duration: TimeInterval = 60
        /// Memory bound for everything but views. Above it the least valuable events go first.
        static let bytesLimit = 64 * 1_024
        static let eventsLimit = 200
        /// Views are the containers their events hang from, so they are kept out of the budget
        /// above; this only bounds pathological navigation counts.
        static let viewsLimit = 50
        /// Correlated errors make every client release at the same moment, right when whatever
        /// caused them is already under strain. Releases are spread over this window instead.
        static let releaseMaxDelay: TimeInterval = 3
    }

    /// What gets dropped first when the buffer is over budget. Lower goes first.
    enum EvictionTier: Int {
        /// Long tasks, and requests that succeeded without complaint.
        case first
        /// Actions, vitals and failed requests: they explain what the user was doing.
        case last
        /// Errors are the reason the session is kept at all, so they go only once nothing else is
        /// left - and then the newest first, because the earliest error is the one the session is
        /// about.
        case lastResort
    }

    private struct HeldEvent {
        let viewID: String
        let time: Date
        let bytes: Int
        let tier: EvictionTier
        let write: (Writer, _ claimingReplayRecords: Int64?) -> Void
        let discard: () -> Void
    }

    private struct HeldView {
        /// The view's start date, as the event reports it.
        let date: Int64
        let write: (Writer, _ claimingReplayRecords: Int64?) -> Void
        let discard: () -> Void
    }

    /// Latest event per view; `viewOrder` keeps them least recently updated first.
    private var views: [String: HeldView] = [:]
    private var viewOrder: [String] = []
    private var details: [HeldEvent] = []
    private var bytes = 0
    private var droppedCount = 0
    private var currentViewID: String?
    private var currentViewDate: Int64 = .min

    /// When the release was scheduled. It freezes the window: a release timer can fire late, and
    /// pruning against a later time would throw away exactly the minute before the error.
    private(set) var releaseScheduledAt: Date?

    /// What a release wrote out, for the telemetry that lets "up to a minute before the error"
    /// be checked against reality.
    struct ReleaseSummary: Equatable {
        let viewsCount: Int
        let eventsCount: Int
        let droppedCount: Int
        let bytes: Int
    }

    /// Holds an assembled event.
    ///
    /// - Returns: `false` when the event was not held because it is an error larger than the whole
    ///   budget; the caller writes it straight away instead, so it neither evicts itself nor the
    ///   history preceding it.
    func hold<E: RUMWithheldEvent, M: Encodable>(
        event: E,
        metadata: M?,
        completion: @escaping CompletionHandler,
        now: Date
    ) -> Bool {
        let write: (Writer, Int64?) -> Void = { writer, records in
            writer.write(value: records.map { event.claimingReplay(records: $0) } ?? event, metadata: metadata, completion: completion)
        }

        if let view = event as? RUMViewEvent {
            holdView(id: view.view.id, date: view.date, write: write, discard: completion)
            prune(now: now)
            return true
        }

        let eventBytes = (try? JSONEncoder.dd.default().encode(event).count) ?? 0
        guard eventBytes <= Constants.bytesLimit else {
            if event is RUMErrorEvent {
                return false
            }
            // A single event larger than the whole budget can never be part of a release, and
            // holding it would evict the entire preceding minute to make room it never fits into.
            droppedCount += 1
            completion()
            return true
        }
        details.append(
            HeldEvent(
                viewID: event.viewID,
                time: now,
                bytes: eventBytes,
                tier: event.evictionTier,
                write: write,
                discard: completion
            )
        )
        bytes += eventBytes

        prune(now: now)
        while details.count > Constants.eventsLimit || bytes > Constants.bytesLimit {
            guard evictOne() else {
                break
            }
        }
        return true
    }

    /// Freezes the window at the time the release is scheduled.
    func freezeWindow(at time: Date) {
        if releaseScheduledAt == nil {
            releaseScheduledAt = time
        }
    }

    /// Writes everything still held, views first (oldest start first, because the backend builds
    /// the session out of whichever view arrives first), then errors, then the rest oldest first:
    /// a release often happens right before the app goes away, and the error must not ride in the
    /// last of what still gets out.
    ///
    /// Views only order the release. A detail whose view is not held - one assembled before any
    /// view event, or whose view was evicted - is released all the same: the error that releases
    /// the session must never be the thing that stays behind.
    ///
    /// - Parameter recordsCountByViewID: the replay records each view still holds. The events
    ///   were assembled while the replay was withheld and could not claim one then; an event whose
    ///   view kept records claims it now, because those records are released alongside it.
    func release(to writer: Writer, now: Date, recordsCountByViewID: [String: Int64] = [:]) -> ReleaseSummary {
        prune(now: now)

        let orderedViews = viewOrder.compactMap { id in views[id].map { (id, $0) } }.sorted { $0.1.date < $1.1.date }
        let keptReplay = { (viewID: String) -> Int64? in recordsCountByViewID[viewID].flatMap { $0 > 0 ? $0 : nil } }

        orderedViews.forEach { id, view in view.write(writer, keptReplay(id)) }
        details.filter { $0.tier == .lastResort }.forEach { $0.write(writer, keptReplay($0.viewID)) }
        details.filter { $0.tier != .lastResort }.forEach { $0.write(writer, keptReplay($0.viewID)) }

        let summary = ReleaseSummary(
            viewsCount: orderedViews.count,
            eventsCount: details.count,
            droppedCount: droppedCount,
            bytes: bytes
        )
        clear()
        return summary
    }

    /// Throws everything away.
    func discard() {
        viewOrder.compactMap { views[$0] }.forEach { $0.discard() }
        details.forEach { $0.discard() }
        clear()
    }

    // MARK: - Private

    private func holdView(id: String, date: Int64, write: @escaping (Writer, Int64?) -> Void, discard: @escaping () -> Void) {
        // Upsert: a view event is cumulative, so the latest one supersedes the ones before it.
        views[id]?.discard()
        viewOrder.removeAll { $0 == id }
        views[id] = HeldView(date: date, write: write, discard: discard)
        viewOrder.append(id)

        // The view in progress is judged by its start date, not by arrival: a late update of a
        // view that already ended must not make it current again, or the next error would hang
        // from a view `prune` is free to drop.
        if date >= currentViewDate {
            currentViewDate = date
            currentViewID = id
        }
        while viewOrder.count > Constants.viewsLimit {
            guard let oldest = viewOrder.first(where: { $0 != currentViewID }) else {
                break
            }
            viewOrder.removeAll { $0 == oldest }
            views.removeValue(forKey: oldest)?.discard()
        }
    }

    /// Drops what has aged out of the window, and the views left with nothing to contain.
    private func prune(now: Date) {
        let oldestAllowed = (releaseScheduledAt ?? now).addingTimeInterval(-Constants.duration)
        while let oldest = details.first, oldest.time < oldestAllowed {
            details.removeFirst()
            bytes -= oldest.bytes
            droppedCount += 1
            oldest.discard()
        }

        // The view in progress always stays: it is the container the error will hang from.
        let viewsWithDetail = Set(details.map { $0.viewID })
        for id in viewOrder where id != currentViewID && !viewsWithDetail.contains(id) {
            views.removeValue(forKey: id)?.discard()
        }
        viewOrder.removeAll { views[$0] == nil }
    }

    /// Removes one event of the least valuable tier present. Returns `false` when none is left.
    private func evictOne() -> Bool {
        for tier in [EvictionTier.first, .last] {
            if let index = details.firstIndex(where: { $0.tier == tier }) {
                evict(at: index)
                return true
            }
        }
        // Only errors are left: the newest goes, so an error storm cannot push out the first one.
        if let index = details.lastIndex(where: { $0.tier == .lastResort }) {
            evict(at: index)
            return true
        }
        return false
    }

    private func evict(at index: Int) {
        let evicted = details.remove(at: index)
        bytes -= evicted.bytes
        droppedCount += 1
        evicted.discard()
    }

    private func clear() {
        views = [:]
        viewOrder = []
        details = []
        bytes = 0
        droppedCount = 0
        currentViewID = nil
        currentViewDate = .min
        releaseScheduledAt = nil
    }

    // MARK: - Release jitter

    /// The release delay of a session, deterministic per session id.
    ///
    /// Multiplicative rather than a running sum: session ids are same-length strings over the same
    /// small alphabet, so summing their characters lands almost every session within a few hundred
    /// milliseconds of the same value - which delays the herd instead of spreading it.
    static func releaseDelay(sessionID: String) -> TimeInterval {
        var hash: Int32 = 0
        for unit in sessionID.utf16 {
            hash = hash &* 31 &+ Int32(unit)
        }
        let milliseconds = abs(Int64(hash)) % Int64(Constants.releaseMaxDelay * 1_000)
        return TimeInterval(milliseconds) / 1_000
    }
}

/// An event the buffer can hold: one that says which view it hangs from.
internal protocol RUMWithheldEvent: Codable {
    var viewID: String { get }
    var evictionTier: RUMWithheldEventBuffer.EvictionTier { get }
}

extension RUMWithheldEvent {
    var evictionTier: RUMWithheldEventBuffer.EvictionTier { .last }

    /// The same event, claiming the session's replay (`session.has_replay`) and, for a view, the
    /// records its view holds (`_dd.replay_stats.records_count`): a view that ended while the
    /// replay was withheld gets no later update to carry the count. The generated models keep the
    /// fields immutable, so they are set through the JSON form the intake receives - the same
    /// encoder, so a custom attribute comes back exactly as it will be sent; an event that does
    /// not round-trip is written as it was.
    func claimingReplay(records: Int64) -> Self {
        guard let data = try? JSONEncoder.dd.default().encode(self),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var session = json["session"] as? [String: Any] else {
            return self
        }
        session["has_replay"] = true
        json["session"] = session
        if json["type"] as? String == "view", var dd = json["_dd"] as? [String: Any] {
            var replayStats = dd["replay_stats"] as? [String: Any] ?? [:]
            replayStats["records_count"] = records
            dd["replay_stats"] = replayStats
            json["_dd"] = dd
        }
        return (try? JSONSerialization.data(withJSONObject: json))
            .flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? self
    }
}

extension RUMViewEvent: RUMWithheldEvent {
    var viewID: String { view.id }
}

extension RUMErrorEvent: RUMWithheldEvent {
    var viewID: String { view.id }
    var evictionTier: RUMWithheldEventBuffer.EvictionTier { .lastResort }
}

extension RUMResourceEvent: RUMWithheldEvent {
    var viewID: String { view.id }
    /// A request that failed is part of how the error happened; one that succeeded rarely is. An
    /// unknown status code is treated like an ordinary success.
    var evictionTier: RUMWithheldEventBuffer.EvictionTier {
        let statusCode = resource.statusCode ?? -1
        return statusCode == 0 || statusCode >= 400 ? .last : .first
    }
}

extension RUMLongTaskEvent: RUMWithheldEvent {
    var viewID: String { view.id }
    var evictionTier: RUMWithheldEventBuffer.EvictionTier { .first }
}

extension RUMActionEvent: RUMWithheldEvent {
    var viewID: String { view.id }
}

extension RUMVitalAppLaunchEvent: RUMWithheldEvent {
    var viewID: String { view.id }
}

extension RUMVitalDurationEvent: RUMWithheldEvent {
    var viewID: String { view.id }
}

extension RUMVitalOperationStepEvent: RUMWithheldEvent {
    var viewID: String { view.id }
}
