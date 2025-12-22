/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import FlashcatInternal

internal struct BacktraceReporter: FlashcatInternal.BacktraceReporting {
    let reporter: ThirdPartyCrashReporter

    func generateBacktrace(threadID: ThreadID) throws -> FlashcatInternal.BacktraceReport? {
        return try reporter.generateBacktrace(threadID: threadID)
    }
}
