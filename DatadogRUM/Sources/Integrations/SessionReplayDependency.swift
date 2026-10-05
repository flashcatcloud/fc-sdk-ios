/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation
import DatadogInternal

// MARK: - Extracting SR context from `DatadogContext`

extension DatadogContext {
    /// The value indicating if replay is being performed by Session Replay.
    var hasReplay: Bool? {
        additionalContext(ofType: SessionReplayCoreContext.HasReplay.self)?.value
    }

    /// The value of `[String: Int64]` that indicates number of records recorded for a given viewID.
    var recordsCountByViewID: [String: Int64] {
        additionalContext(ofType: SessionReplayCoreContext.RecordsCount.self)?.value ?? [:]
    }

    /// FLASHCAT FORK - the replay of the given session when it is kept only in case the session
    /// reports an error; `nil` for any other replay, and for one published for another session.
    func errorReplay(of sessionID: RUMUUID) -> SessionReplayCoreContext.ErrorReplay? {
        additionalContext(ofType: SessionReplayCoreContext.ErrorReplay.self)
            .flatMap { $0.sessionID == sessionID.toRUMDataFormat ? $0 : nil }
    }

    /// FLASHCAT FORK - whether an error in the given view claims a replay that is still withheld.
    /// The error is what releases it, so the records its view still holds are uploaded alongside
    /// it; it is the event the console opens the replay from. Judged by what the view holds, not
    /// by the recorder running: a view whose withheld records were all thrown away has nothing
    /// to offer.
    func withheldReplayIsHeld(for sessionID: RUMUUID, in viewID: RUMUUID?) -> Bool {
        guard errorReplay(of: sessionID)?.withheld == true, let viewID = viewID else {
            return false
        }
        return (recordsCountByViewID[viewID.toRUMDataFormat] ?? 0) > 0
    }
}
