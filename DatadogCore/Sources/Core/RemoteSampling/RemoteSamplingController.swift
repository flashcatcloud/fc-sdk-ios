/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation
import DatadogInternal

/// Keeps the stored sampling configuration in step with what the console says.
///
/// The fetch model is session-driven: RUM publishes `RemoteSamplingSource` when the SDK starts and
/// again every time a session begins, and each publication is one opportunity to fetch. There is no
/// polling — the console's `ttl` is intentionally not honoured on iOS. A request in flight
/// deduplicates triggers; a failed request is retried after 5s and then 60s (±20% jitter), after
/// which the controller waits for the next trigger. Nothing here can hold up the SDK or interrupt
/// collection: a request that fails, times out or comes back unreadable leaves the stored values
/// exactly as they were. Wiping them on a bad minute would swing a whole fleet back to the rates it
/// was built with, which is the opposite of what someone who turned a knob deliberately wants.
internal final class RemoteSamplingController {
    /// The delays before the first and second retry of a failed fetch.
    private static let retryDelays: [TimeInterval] = [5, 60]

    /// The queue every piece of state below lives on.
    private let queue = DispatchQueue(label: "com.datadoghq.remote-sampling", target: .global(qos: .utility))

    private let httpClient: HTTPClient
    private let contextProvider: DatadogContextProvider
    private let store: RemoteSamplingSnapshotStore?
    private let telemetry: Telemetry

    /// Hands the rates to the core, which publishes them as additional context for all features.
    private let publishRates: (RemoteSamplingRates) -> Void
    /// Tells the core the rates changed, with the console's instruction about the running
    /// session; the core passes it to RUM on the bus, which is where that instruction is judged.
    private let notifyRatesChanged: (RemoteSamplingActivation) -> Void
    /// Schedules a retry; injectable so tests do not wait.
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    /// Applies ±20% jitter to a retry delay; injectable so tests are deterministic.
    private let jitter: (TimeInterval) -> TimeInterval

    /// The snapshot currently in effect, mirrored to disk after every change.
    private var snapshot: RemoteSamplingSnapshot = .empty
    /// The rates the snapshot resolves to, readable without waiting on `queue`.
    ///
    /// The context is how these reach every other feature, but a session draw cannot wait for a
    /// queue hop — it happens now, and the answer has to be the one already on disk.
    @ReadWriteLock
    private(set) var currentRates: RemoteSamplingRates?
    /// The storage key of the running configuration; `nil` until the first source is seen.
    private var storageKey: String?
    /// Whether the stored snapshot was already loaded for `storageKey`.
    private var didLoadStoredSnapshot = false
    /// Whether a fetch or a pending retry is in flight, deduplicating triggers.
    private var inFlight = false
    /// How many retries the current fetch chain already used.
    private var retryAttempt = 0
    /// The last source a trigger arrived with; retries aim at the same address.
    private var lastSource: RemoteSamplingSource?

    init(
        httpClient: HTTPClient,
        contextProvider: DatadogContextProvider,
        store: RemoteSamplingSnapshotStore?,
        telemetry: Telemetry,
        publishRates: @escaping (RemoteSamplingRates) -> Void,
        notifyRatesChanged: @escaping (RemoteSamplingActivation) -> Void,
        schedule: ((TimeInterval, @escaping () -> Void) -> Void)? = nil,
        jitter: ((TimeInterval) -> TimeInterval)? = nil
    ) {
        self.httpClient = httpClient
        self.contextProvider = contextProvider
        self.store = store
        self.telemetry = telemetry
        self.publishRates = publishRates
        self.notifyRatesChanged = notifyRatesChanged
        self.schedule = schedule ?? { delay, work in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
        }
        self.jitter = jitter ?? { delay in
            delay * Double.random(in: 0.8...1.2)
        }
    }

    /// Handles a publication of `RemoteSamplingSource`: one opportunity to fetch.
    ///
    /// Called by the core every time a feature sets the source, which RUM does at SDK init and at
    /// every session creation. The first publication for a storage key also loads the snapshot
    /// persisted by a previous launch and publishes it, so the values the console last provided
    /// apply again before the network answers.
    func onSourcePublished(_ source: RemoteSamplingSource) {
        queue.async {
            self.contextProvider.read { context in
                self.queue.async {
                    self.handleTrigger(source: source, context: context)
                }
            }
        }
    }

    // MARK: - Private; every method below runs on `queue`

    /// Loads what a previous launch stored for this source, exactly once per storage key.
    ///
    /// Runs on `queue` like every other piece of state here — reached either from a trigger or,
    /// before any session exists, from `prime(source:context:)`.
    private func loadStoredSnapshotIfNeeded(source: RemoteSamplingSource, context: DatadogContext) {
        lastSource = source
        let key = RemoteSamplingSnapshotStore.key(source: source, context: context)
        if key != storageKey {
            storageKey = key
            didLoadStoredSnapshot = false
            snapshot = .empty
            currentRates = nil
        }
        guard !didLoadStoredSnapshot else {
            return
        }
        didLoadStoredSnapshot = true
        if let stored = store?.load(forKey: key), stored.version > 0 {
            snapshot = stored
            currentRates = stored.rates
            publishRates(stored.rates)
        }
    }

    /// Reads the stored configuration into effect before anything can be drawn under it.
    ///
    /// Blocking is the point: the caller is about to draw a session, and the whole reason the
    /// snapshot is on disk is so that draw uses it rather than the values the app was built with.
    /// It only touches storage — no request is made here.
    func prime(source: RemoteSamplingSource, context: DatadogContext) -> RemoteSamplingRates? {
        queue.sync {
            loadStoredSnapshotIfNeeded(source: source, context: context)
        }
        return currentRates
    }

    private func handleTrigger(source: RemoteSamplingSource, context: DatadogContext) {
        loadStoredSnapshotIfNeeded(source: source, context: context)

        guard !inFlight else {
            return
        }
        inFlight = true
        retryAttempt = 0
        fetch(source: source)
    }

    private func fetch(source: RemoteSamplingSource) {
        var components = URLComponents(url: source.configurationURL, resolvingAgainstBaseURL: false)
        if snapshot.version > 0 {
            // Telling the server which version this app runs is what lets the console answer
            // "has my change reached everyone yet".
            var items = components?.queryItems ?? []
            items.append(URLQueryItem(name: "applied_version", value: String(snapshot.version)))
            components?.queryItems = items
        }

        guard let url = components?.url else {
            telemetry.error("Remote sampling: could not build the configuration URL from \(source.configurationURL)")
            inFlight = false
            return
        }

        var request = URLRequest(url: url)
        if let etag = snapshot.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        httpClient.fetch(request: request) { [weak self] result in
            self?.queue.async {
                self?.handleResponse(result)
            }
        }
    }

    private func handleResponse(_ result: Result<(response: HTTPURLResponse, body: Data), Error>) {
        switch result {
        case .success((let response, let body)) where response.statusCode == 200:
            do {
                let parsed = try RemoteSamplingResponse.parse(body: body, etag: Self.etag(of: response), telemetry: telemetry)
                activate(parsed)
            } catch let error as RemoteSamplingUnsupportedSchemaError {
                // The server answered; this SDK simply cannot use the answer until it is updated.
                // Asking again would fetch the same refusal, so the ask is over.
                telemetry.error(
                    """
                    Remote sampling: ignoring a configuration written to schema version \
                    \(error.received.map(String.init) ?? "none"); this SDK reads version \
                    \(RemoteSamplingResponse.supportedSchemaVersion). Update the SDK to take the \
                    console's settings again.
                    """
                )
                inFlight = false
            } catch {
                telemetry.debug("Remote sampling: rejecting an invalid configuration response, keeping the previous one")
                scheduleRetry()
            }
        case .success((let response, _)) where response.statusCode == 304:
            inFlight = false
        case .success((let response, _)) where Self.isARefusal(response.statusCode):
            // A refusal is not a hiccup: the same request gets the same answer. Retrying spends two
            // more requests per session on a verdict that will not change — and the ordinary way to
            // land here is a private deployment whose proxy has no `/config` route at all, where
            // that waste is paid by every session of every client.
            telemetry.debug("Remote sampling: the configuration endpoint refused the request (\(response.statusCode)); waiting for the next trigger")
            inFlight = false
        case .success((let response, _)):
            telemetry.debug("Remote sampling: configuration request answered \(response.statusCode), keeping the previous values")
            scheduleRetry()
        case .failure(let error):
            telemetry.debug("Remote sampling: configuration request failed (\(error.localizedDescription)), keeping the previous values")
            scheduleRetry()
        }
    }

    /// Activates a validated snapshot all-or-nothing: persist it, publish its rates, and when the
    /// rates this client draws with really changed, tell RUM so.
    ///
    /// Every real change is reported, not only the ones the console marked `immediate`: a rate of
    /// zero ends the running session on its own meaning, without the console having to ask. What to
    /// do about it is decided in RUM, which is the only side that knows whether the visitor was
    /// forced, whether the session is being collected, and what rate applies once a cleared knob
    /// falls back to the value the app was initialised with.
    private func activate(_ parsed: RemoteSamplingResponse) {
        // A body older than what is already in force is a stale copy — an edge cache or a proxy
        // answering 200 with something it held on to. Versions only ever climb: a rollback in the
        // console republishes the older content under a new number, and pruning removes the oldest
        // rows, so the newest version never goes down. Applying one that did would put this client
        // back on settings the console has already replaced, and it would keep reporting that older
        // number, so the rollout view would read as the change losing ground.
        guard parsed.snapshot.version >= snapshot.version else {
            telemetry.debug("Remote sampling: ignoring a configuration older than the one in force")
            inFlight = false
            return
        }

        let previousSessionSampleRate = snapshot.rates.sessionSampleRate
        snapshot = parsed.snapshot
        if let storageKey = storageKey {
            store?.save(snapshot, forKey: storageKey)
        }
        currentRates = snapshot.rates
        publishRates(snapshot.rates)
        inFlight = false

        let drawChanged = previousSessionSampleRate != snapshot.rates.sessionSampleRate
        if drawChanged {
            notifyRatesChanged(parsed.activation)
        }
    }

    /// The validator the server stamped this response with.
    ///
    /// Read from the response rather than recomputed from the body: how the server derives its
    /// validator is the server's business, and a client that reimplements it has to be updated in
    /// lockstep with it forever. Get that wrong — the server changes the derivation, or anything
    /// on the way re-serialises the body — and every conditional request misses, silently: the
    /// answers stay correct and each one arrives in full, which costs bandwidth without ever
    /// failing loudly enough to be noticed.
    ///
    /// Looked up case-insensitively because HTTP field names are, and `allHeaderFields` keeps
    /// whatever case the server wrote (`value(forHTTPHeaderField:)` would do this for us, but it
    /// is iOS 13 and this SDK supports 12).
    private static func etag(of response: HTTPURLResponse) -> String? {
        for (name, value) in response.allHeaderFields {
            if let name = name as? String, name.caseInsensitiveCompare("ETag") == .orderedSame {
                return value as? String
            }
        }
        return nil
    }

    /// Whether the server has refused this request rather than failed to answer it.
    ///
    /// `408` and `429` are the two 4xx that mean "not now" rather than "not ever", so they keep
    /// the retry they would have had.
    private static func isARefusal(_ statusCode: Int) -> Bool {
        (400..<500).contains(statusCode) && statusCode != 408 && statusCode != 429
    }

    private func scheduleRetry() {
        guard retryAttempt < Self.retryDelays.count else {
            // Out of retries: keep the stored values and wait for the next session trigger.
            inFlight = false
            return
        }
        let delay = jitter(Self.retryDelays[retryAttempt])
        retryAttempt += 1
        schedule(delay) { [weak self] in
            self?.queue.async {
                // The retry only fires when the chain is still expected to be in flight.
                guard let self = self, self.inFlight, let source = self.lastSource else {
                    return
                }
                self.fetch(source: source)
            }
        }
    }
}
