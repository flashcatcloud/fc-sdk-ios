/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation
import DatadogInternal

/// FLASHCAT FORK - tells the intake that the app is in use: at most one beacon per local day,
/// device and user.
///
/// Sent on its own request rather than through the batch pipeline. A session of a few seconds is
/// only uploaded on the next launch, and dropped if that launch comes too late, so the device
/// would not count as active the day it was used. "Already sent today" is judged on the device's
/// local date and only saves requests: repeats are idempotent on the intake, which dates a beacon
/// by its own receive time less `age_ms`.
///
/// Every context update is a chance to send, and one is taken only when something the beacon
/// depends on has changed: the app coming to the foreground, tracking consent, the anonymous or
/// user id, or the local day. That covers the launch (once the anonymous id is read), returning
/// to the foreground, consent being granted, a new user being set and midnight passing while the
/// app is in front, and it keeps an undeliverable beacon from being retried on every update.
///
/// Sent only while the app is active in the foreground with consent granted; session sampling
/// does not apply. The beacon is stored before it is sent, so one the process does not live to
/// deliver - the app suspended or killed with the request on the wire - is sent with its age on a
/// later launch, as is one still failing after the retries. At most one is stored, and one older
/// than 72 hours is dropped. Nothing stored outlives consent being withdrawn.
internal final class ActiveDeviceBeacon: FeatureMessageReceiver {
    /// The request body, as the intake reads it.
    struct Body: Codable, Equatable {
        struct User: Codable, Equatable {
            let anonymousId: String?
            let id: String?

            enum CodingKeys: String, CodingKey {
                case anonymousId = "anonymous_id"
                case id
            }
        }

        struct OS: Codable, Equatable {
            let name: String
            let version: String
        }

        struct Device: Codable, Equatable {
            let type: String
            let model: String
            let brand: String
        }

        let service: String
        let env: String
        let version: String
        let buildVersion: String
        let sdkVersion: String
        let usr: User
        let os: OS
        let device: Device
        /// How long before sending the app was in use.
        var ageMs: Int64

        enum CodingKeys: String, CodingKey {
            case service, env, version
            case buildVersion = "build_version"
            case sdkVersion = "sdk_version"
            case usr, os, device
            case ageMs = "age_ms"
        }
    }

    /// A beacon not yet delivered: its body, when the app was in use, and the day and identity it
    /// reports.
    struct Record: Codable, Equatable {
        let body: Body
        let usedAt: Date
        let key: String
    }

    /// What decides whether there is anything to send. A context update that changes none of it
    /// is not a trigger.
    private struct Trigger: Equatable {
        let isInForeground: Bool
        let consent: TrackingConsent
        let anonymousId: String?
        let userId: String?
        let day: String
    }

    /// The intake refuses a beacon older than this; it is dropped here instead.
    static let maxAge: TimeInterval = 72 * 60 * 60
    /// The intake stores at most this many bytes of a string field (UTF-8).
    static let maxFieldBytes = 255
    /// How long one request may take. Nothing waits on it, and a stalled one holds back the next.
    static let requestTimeout: TimeInterval = 10

    private let featureScope: FeatureScope
    private weak var sender: DirectRequestSender?
    private let customEndpoint: URL?
    private let trackAnonymousUser: Bool
    private let dateProvider: DateProvider
    private let retryDelays: [TimeInterval]
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    /// Every piece of state below lives on this queue.
    let queue: DispatchQueue

    private var context: DatadogContext?
    private var trigger: Trigger?
    /// Whether what a previous launch stored was read. Nothing is decided before.
    private var isLoaded = false
    /// The key of the last beacon delivered (or refused).
    private var sentKey: String?
    private var pending: Record?
    /// Whether a beacon is on the wire or waiting to be retried.
    private var isSending = false
    /// Whether consent was withdrawn before what was stored could be read: what the read returns
    /// was deleted meanwhile and must not come back.
    private var storedValuesWereForgotten = false

    init(
        featureScope: FeatureScope,
        sender: DirectRequestSender,
        customEndpoint: URL?,
        trackAnonymousUser: Bool,
        dateProvider: DateProvider,
        retryDelays: [TimeInterval] = [2, 8],
        schedule: ((TimeInterval, @escaping () -> Void) -> Void)? = nil,
        queue: DispatchQueue = DispatchQueue(label: "com.datadoghq.rum-active-beacon", target: .global(qos: .utility))
    ) {
        self.featureScope = featureScope
        self.sender = sender
        self.customEndpoint = customEndpoint
        self.trackAnonymousUser = trackAnonymousUser
        self.dateProvider = dateProvider
        self.retryDelays = retryDelays
        self.queue = queue
        self.schedule = schedule ?? { [queue] delay, work in
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        }

        let dataStore = featureScope.rumDataStore
        dataStore.value(forKey: .activeBeaconSent) { [weak self] (sentKey: String?) in
            dataStore.value(forKey: .activeBeaconPending) { (pending: Record?) in
                self?.queue.async {
                    guard let self = self else {
                        return
                    }
                    self.isLoaded = true
                    if !self.storedValuesWereForgotten {
                        self.sentKey = sentKey
                        self.pending = pending
                    }
                    self.evaluate()
                }
            }
        }
    }

    /// Deletes what the beacon stored: both records name the device and the user.
    static func discardStored(in featureScope: FeatureScope) {
        featureScope.rumDataStore.removeValue(forKey: .activeBeaconSent)
        featureScope.rumDataStore.removeValue(forKey: .activeBeaconPending)
    }

    // MARK: - FeatureMessageReceiver

    func receive(message: FeatureMessage, from core: DatadogCoreProtocol) -> Bool {
        guard case .context(let context) = message else {
            return false
        }
        let now = dateProvider.now
        queue.async {
            self.context = context
            let trigger = self.trigger(for: context, at: now)
            guard trigger != self.trigger else {
                return
            }
            if context.trackingConsent == .notGranted, self.trigger?.consent != .notGranted {
                self.forget()
            }
            self.trigger = trigger
            self.evaluate()
        }
        return false // context updates are broadcast; claiming them would only suppress the fallback
    }

    // MARK: - Private; every method below runs on `queue`

    private func evaluate() {
        guard isLoaded, !isSending, let context = context, canSend(in: context) else {
            return
        }
        let now = dateProvider.now
        if let stored = pending, now.timeIntervalSince(stored.usedAt) > Self.maxAge {
            DD.logger.debug("RUM active beacon: dropping a beacon older than 72 hours")
            setPending(nil)
        }
        if pending == nil {
            guard let key = key(for: context, at: now), key != sentKey else {
                return
            }
            setPending(Record(body: body(for: context), usedAt: now, key: key))
        }
        guard let record = pending else {
            return
        }
        isSending = true
        send(record, attempt: 0)
    }

    private func send(_ record: Record, attempt: Int) {
        guard pending == record else {
            // Consent was withdrawn during the backoff, which dropped this record, and granted
            // again: it is not sent; the new grant reports the device afresh.
            isSending = false
            evaluate()
            return
        }
        guard let context = context, canSend(in: context) else {
            isSending = false // consent changed meanwhile; what is stored stays for a later trigger
            return
        }
        guard let sender = sender, let request = request(for: record, in: context) else {
            isSending = false
            return
        }
        sender.sendDirectly(request: request) { [weak self] result in
            self?.queue.async {
                self?.handle(result, for: record, attempt: attempt)
            }
        }
    }

    private func handle(_ result: Result<HTTPURLResponse, Error>, for record: Record, attempt: Int) {
        // Consent can be withdrawn while the request is on the wire: nothing that names the device
        // or the user is written after that - not even once it is granted again, which the record
        // no longer being the stored one tells.
        guard context?.trackingConsent == .granted, pending == record else {
            isSending = false
            evaluate()
            return
        }
        let statusCode: Int? = {
            if case .success(let response) = result {
                return response.statusCode
            }
            return nil
        }()
        let delivered = statusCode.map { (200..<300).contains($0) } ?? false
        // A refusal is final: the same body gets the same answer. 429 only means "not now".
        let refused = statusCode.map { (400..<500).contains($0) && $0 != 429 } ?? false

        if delivered || refused {
            if refused {
                DD.logger.debug("RUM active beacon: the intake refused it (\(statusCode ?? 0))")
            }
            setPending(nil)
            sentKey = record.key
            featureScope.rumDataStore.setValue(record.key, forKey: .activeBeaconSent)
            isSending = false
            evaluate() // a trigger may have arrived meanwhile, or the record was from an earlier day
            return
        }
        guard attempt < retryDelays.count else {
            // Still stored: sent on a later trigger, with its age.
            DD.logger.debug("RUM active beacon: could not be sent, keeping it for later")
            isSending = false
            return
        }
        schedule(retryDelays[attempt]) { [weak self] in
            self?.queue.async {
                self?.send(record, attempt: attempt + 1)
            }
        }
    }

    private func forget() {
        sentKey = nil
        pending = nil
        storedValuesWereForgotten = !isLoaded
        Self.discardStored(in: featureScope)
    }

    private func setPending(_ record: Record?) {
        pending = record
        if let record = record {
            featureScope.rumDataStore.setValue(record, forKey: .activeBeaconPending)
        } else {
            featureScope.rumDataStore.removeValue(forKey: .activeBeaconPending)
        }
    }

    /// Consent granted, and the app active in the foreground - never a background launch or a
    /// prewarm, which do not become active until the user actually opens the app.
    private func canSend(in context: DatadogContext) -> Bool {
        context.trackingConsent == .granted && isInForeground(context)
    }

    private func isInForeground(_ context: DatadogContext) -> Bool {
        context.applicationBundleType == .iOSApp && context.applicationStateHistory.currentState == .active
    }

    private func trigger(for context: DatadogContext, at date: Date) -> Trigger {
        Trigger(
            isInForeground: isInForeground(context),
            consent: context.trackingConsent,
            anonymousId: nonEmpty(context.userInfo?.anonymousId),
            userId: nonEmpty(context.userInfo?.id),
            day: Self.localDay(of: date)
        )
    }

    /// Local day + anonymous id + user id; nil while there is no identity to report. With anonymous
    /// tracking on, that waits for the anonymous id, which is read from disk after start.
    private func key(for context: DatadogContext, at date: Date) -> String? {
        let anonymousId = nonEmpty(context.userInfo?.anonymousId)
        let userId = nonEmpty(context.userInfo?.id)
        if trackAnonymousUser ? anonymousId == nil : userId == nil {
            return nil
        }
        return "\(Self.localDay(of: date))|\(anonymousId ?? "")|\(userId ?? "")"
    }

    private func body(for context: DatadogContext) -> Body {
        Body(
            service: Self.cut(context.service),
            env: Self.cut(context.env),
            version: Self.cut(context.version),
            buildVersion: Self.cut(context.buildNumber),
            sdkVersion: Self.cut(context.sdkVersion),
            usr: Body.User(
                anonymousId: nonEmpty(context.userInfo?.anonymousId).map(Self.cut),
                id: nonEmpty(context.userInfo?.id).map(Self.cut)
            ),
            os: Body.OS(name: Self.cut(context.os.name), version: Self.cut(context.os.version)),
            device: Body.Device(
                type: context.device.type.normalizedDeviceType.rawValue,
                model: Self.cut(context.device.model),
                brand: Self.cut(context.device.brand)
            ),
            ageMs: 0
        )
    }

    /// `{intake}/active?dd-api-key=...`, beside the event intake - a custom endpoint included, as the
    /// remote configuration is.
    private func request(for record: Record, in context: DatadogContext) -> URLRequest? {
        let intake = customEndpoint ?? context.site.endpoint.appendingPathComponent("api/v2/rum")
        guard var components = URLComponents(url: intake.appendingPathComponent("active"), resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "dd-api-key", value: context.clientToken)]
        guard let url = components.url else {
            return nil
        }
        var body = record.body
        body.ageMs = max(0, dateProvider.now.timeIntervalSince(record.usedAt)).dd.toInt64Milliseconds
        guard let data = try? JSONEncoder().encode(body) else {
            return nil
        }
        var request = URLRequestBuilder(
            url: url,
            queryItems: [],
            headers: [
                .contentTypeHeader(contentType: .applicationJSON),
                .userAgentHeader(appName: context.applicationName, appVersion: context.version, device: context.device, os: context.os)
            ],
            telemetry: featureScope.telemetry
        ).uploadRequest(with: data, compress: false)
        request.timeoutInterval = Self.requestTimeout
        return request
    }

    private func nonEmpty(_ value: String?) -> String? {
        value.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func localDay(of date: Date) -> String {
        let day = Calendar(identifier: .gregorian).dateComponents(in: .autoupdatingCurrent, from: date)
        return String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }

    /// At most `maxFieldBytes` bytes of UTF-8, cut between characters. The intake's columns are
    /// bounded in bytes, so 255 characters of CJK text would not fit; a byte cut is also never
    /// more than 255 characters.
    static func cut(_ value: String) -> String {
        guard value.utf8.count > maxFieldBytes else {
            return value
        }
        var bytes = 0
        var end = value.startIndex
        for index in value.indices {
            let characterBytes = value[index].utf8.count
            if bytes + characterBytes > maxFieldBytes {
                break
            }
            bytes += characterBytes
            end = value.index(after: index)
        }
        return String(value[..<end])
    }
}
