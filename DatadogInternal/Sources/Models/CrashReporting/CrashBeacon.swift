/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation

// FLASHCAT FORK - the crash beacon, sent by Crash Reporting while a foreground crash takes the
// process down. RUM owns the intake it goes to, so RUM publishes where to send it.

/// Where Crash Reporting sends a crash beacon, published by RUM in the core context.
public struct CrashBeaconSource: AdditionalContext, Equatable {
    public static let key = "crash-beacon-source"

    /// `<RUM intake>/crash`, with the client token in the query.
    public let url: URL
    /// The RUM application the beacon counts a crash for.
    public let applicationID: String

    public init(url: URL, applicationID: String) {
        self.url = url
        self.applicationID = applicationID
    }
}

/// Sends the crash beacon from a process that is crashing. The core implements it with the HTTP client
/// of the uploads, so the beacon can reuse their connection and follows the proxy configured at
/// initialisation. It asks UIKit for no background task: the process is ending, and the call could
/// wait on a lock the crashed thread holds.
public protocol CrashBeaconRequestSender: AnyObject {
    /// Sends `request` and hands back how the server answered.
    func sendFromCrashingProcess(request: URLRequest, completion: @escaping (Result<HTTPURLResponse, Error>) -> Void)
}

/// What became of the beacon of a crash, read on the next launch and reported with the crash.
public struct CrashBeaconResult: Codable, Equatable {
    public enum Status: String, Codable {
        /// The intake accepted it.
        case sent
        /// No answer within the wait, or the beacon thread could not run.
        case timeout
        /// The request failed.
        case failed
        /// Not sent: the app was in the background, or beacons were off.
        case skipped
    }

    public let status: Status
    /// Milliseconds the beacon took.
    public let duration: Int64
    /// The `launch_time` the beacon carried (server-corrected process start, ms), so the intake files
    /// the late report under the same day as the beacon. `nil` if none was recorded.
    public let launchTime: Int64?

    public init(status: Status, duration: Int64, launchTime: Int64? = nil) {
        self.status = status
        self.duration = duration
        self.launchTime = launchTime
    }
}
