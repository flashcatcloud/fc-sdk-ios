/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation

/// Context describing Session Replay recording state.
public enum SessionReplayCoreContext {
    /// Boolean `has_replay` context.
    public struct HasReplay: AdditionalContext {
        public static let key = "has_replay"

        /// The `has_replay` value
        public let value: Bool

        /// Creates a Context value.
        ///
        /// - Parameter value: The `has_replay` value
        public init(value: Bool) {
            self.value = value
        }
    }

    /// Count of records per RUM View ID.
    public struct RecordsCount: AdditionalContext {
        public static let key = "sr_records_count_by_view_id"

        /// The `sr_records_count_by_view_id` value
        public let value: [String: Int64]

        /// Creates a Context value.
        ///
        /// - Parameter value: The `sr_records_count_by_view_id` value
        public init(value: [String: Int64]) {
            self.value = value
        }
    }

    /// FLASHCAT FORK - the replay of a session that is kept only in case the session reports an
    /// error (`sessionReplayOnError`, or a session kept on error by RUM). Absent for any other
    /// replay.
    public struct ErrorReplay: AdditionalContext, Equatable {
        public static let key = "sr_error_replay"

        /// The RUM session the replay belongs to.
        public let sessionID: String
        /// Whether its records are still withheld, waiting for the session's error.
        public let withheld: Bool

        public init(sessionID: String, withheld: Bool) {
            self.sessionID = sessionID
            self.withheld = withheld
        }
    }

    /// The Session Replay configuration.
    public struct Configuration: AdditionalContext {
        public static let key = "sr_configuration"

        /// The sample rate for session replay.
        public let sampleRate: SampleRate
        /// Whether session replay recording should be started manually.
        public let startRecordingManually: Bool

        /// Creates a Session Replay configuration.
        ///
        /// - Parameters:
        ///   - sampleRate: The sample rate for session replay.
        ///   - startRecordingManually: Whether session replay recording should be started manually.
        public init(
            sampleRate: SampleRate,
            startRecordingManually: Bool
        ) {
            self.sampleRate = sampleRate
            self.startRecordingManually = startRecordingManually
        }
    }
}
