/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation

/// The RUM context received from `Core`.
public struct RUMCoreContext: AdditionalContext, Equatable {
    /// RUM key in core additional context.
    public static let key = "rum"
    /// Current RUM application ID - standard UUID string, lowercased.
    public let applicationID: String
    /// Current RUM session ID - standard UUID string, lowercased.
    public let sessionID: String
    /// Current RUM view ID - standard UUID string, lowercased. It can be empty when view is being loaded.
    public let viewID: String?
    /// The ID of current RUM action (standard UUID `String`, lowercased).
    public let userActionID: String?
    /// Current view related server time offset
    public let viewServerTimeOffset: TimeInterval?
    /// FLASHCAT FORK - whether the host application forced this session to be collected. Session
    /// Replay skips its own draw when it is set, because a forced session must come out with
    /// replay: forcing exists to debug one visitor, and a replay-less recording of them is not the
    /// thing that was asked for.
    public let sessionForced: Bool
    /// FLASHCAT FORK - whether the session is kept only in case it reports an error and its events
    /// are still withheld (`sessionOnError`). Nothing else may be uploaded for the session then:
    /// if it never errors, it must never reach the backend.
    public let eventsWithheld: Bool
    /// FLASHCAT FORK - whether the session has reported an error: one that was assembled and
    /// survived the event mapper. A replay kept only in case of an error is released by it.
    public let hasReportedError: Bool

    /// Creates a RUM context.
    ///
    /// - Parameters:
    ///   - applicationID: Current RUM application ID - standard UUID string, lowercased.
    ///   - sessionID: Current RUM session ID - standard UUID string, lowercased.
    ///   - viewID: Current RUM view ID - standard UUID string, lowercased. It can be empty when view is being loaded.
    ///   - userActionID: The ID of current RUM action (standard UUID `String`, lowercased).
    ///   - viewServerTimeOffset: Current view related server time offset
    ///   - sessionForced: Whether the host application forced this session to be collected.
    ///   - eventsWithheld: Whether the session's events are withheld until it reports an error.
    ///   - hasReportedError: Whether the session has reported an error.
    public init(
        applicationID: String,
        sessionID: String,
        viewID: String? = nil,
        userActionID: String? = nil,
        viewServerTimeOffset: TimeInterval? = nil,
        sessionForced: Bool = false,
        eventsWithheld: Bool = false,
        hasReportedError: Bool = false
    ) {
        self.applicationID = applicationID
        self.sessionID = sessionID
        self.viewID = viewID
        self.userActionID = userActionID
        self.viewServerTimeOffset = viewServerTimeOffset
        self.sessionForced = sessionForced
        self.eventsWithheld = eventsWithheld
        self.hasReportedError = hasReportedError
    }
}
