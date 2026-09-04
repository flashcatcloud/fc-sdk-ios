/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import DatadogInternal
import Foundation

internal struct RUMContext {
    /// The ID of RUM application.
    let rumApplicationID: String
    /// The ID of current RUM session. May change over time.
    var sessionID: RUMUUID
    /// Whether the session for this context is currently active
    var isSessionActive: Bool
    /// The precondition that led to the creation of current session.
    var sessionPrecondition: RUMSessionPrecondition?

    /// The ID of currently displayed view.
    var activeViewID: RUMUUID?
    /// The path of currently displayed view.
    var activeViewPath: String?
    /// The name of currently displayed view.
    var activeViewName: String?
    /// The ID of active user action.
    var activeUserActionID: RUMUUID?

    /// The configuration the current session was drawn with; `nil` when nothing moved the draw
    /// away from the value the app was initialised with. Fixed for the session's life — it never
    /// changes mid-session.
    var drawnConfiguration: RUMDrawnConfiguration?

    /// The rate this session was actually drawn with, which is what every event it produces
    /// reports. Falls back to the value the app was initialised with, because that is then the
    /// rate that decided it.
    func reportedSessionSampleRate(initialisedWith sampler: Sampler) -> Double {
        Double(drawnConfiguration?.sessionSampleRate ?? sampler.samplingRate)
    }

    /// Whether the host application forced this session to be collected. Session Replay reads it
    /// through the core context so a forced session comes out with replay.
    var sessionForced: Bool = false
}
