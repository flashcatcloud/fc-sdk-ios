/*
* Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
* This product includes software developed at Datadog (https://www.datadoghq.com/).
* Copyright 2019-Present Datadog, Inc.
*/

// FLASHCAT FORK - the crash beacon: a few hundred bytes sent while a foreground crash takes the
// process down, so the crash is counted even if the app is never opened again.
//
// The crashed thread runs only this file's signal handler, which uses async-signal-safe calls
// alone: it wakes the beacon thread through a pipe and waits for its answer with poll(), bounded
// by the timeout. Building and sending the beacon happens on that ordinary thread, prepared at
// startup. The handler is installed before KSCrash, so KSCrash records it as the previous handler
// and re-raises into it once the crash report is on disk and the other threads run again.

#ifndef DDCrashBeacon_h
#define DDCrashBeacon_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// What became of a beacon, as recorded for the next launch.
typedef enum {
    DDCrashBeaconResultNone = 0,
    DDCrashBeaconResultSent = 1,
    DDCrashBeaconResultTimeout = 2,
    DDCrashBeaconResultFailed = 3,
    DDCrashBeaconResultSkipped = 4,
} DDCrashBeaconResult;

enum {
    /// Length of a lowercase UUID string, the form crash ids take.
    DDCrashBeaconIdLength = 36,
    /// Size of a result record: result (1 byte), duration in ms (int32, little-endian), crash id,
    /// then the `launch_time` the beacon carries (int64 ms, little-endian).
    DDCrashBeaconRecordSize = 1 + 4 + 36 + 8,
};

/// Creates the pipes and installs the signal handler and the uncaught exception hook. Must run
/// before KSCrash installs. Does nothing, and returns false, when a debugger is attached (KSCrash
/// masks its own signal handler then too) or when called a second time.
///
/// - Parameters:
///   - resultPath: where this process records its result (copied).
///   - crashId: this process's crash id, `DDCrashBeaconIdLength` characters (copied).
bool dd_crash_beacon_install(const char *resultPath, const char *crashId);

/// Runs the beacon for a crash on the crashed thread, if it has not run yet; a later crash waits for
/// that beacon to end. For a caller that may keep the signal from reaching the handler
/// `dd_crash_beacon_install` installed. Async-signal-safe.
void dd_crash_beacon_handle_crash(int sigNum);
/// Blocks until `isSettled` returns true or `limitMs` pass. Returns whether it settled.
/// Async-signal-safe when `isSettled` is.
bool dd_crash_beacon_wait_until(bool (*isSettled)(void), int32_t limitMs);

/// Whether a crash now sends a beacon. Off until the app is ready to send one.
void dd_crash_beacon_set_armed(bool armed);
/// Beacons are only sent for a crash in the foreground.
void dd_crash_beacon_set_foreground(bool foreground);
/// How long the crashed thread waits, clamped to 500...2000 ms.
void dd_crash_beacon_set_timeout_ms(int32_t timeoutMs);
int32_t dd_crash_beacon_timeout_ms(void);
/// The `launch_time` the beacon sends (server-corrected process start, ms since 1970). Kept here so
/// that every result record carries the same value, including the one the crashed thread writes
/// on a timeout, and the late report can hand it back to the intake.
void dd_crash_beacon_set_launch_time_ms(int64_t launchTimeMs);
/// The value set when the crash fired (0 before any crash): later updates do not change it.
int64_t dd_crash_beacon_launch_time_ms(void);

/// Blocks the beacon thread until a crash wakes it. Returns the signal number, or -1.
int dd_crash_beacon_wait_for_wake(void);
/// The name and reason of the uncaught NSException that caused the crash, or empty strings.
const char *dd_crash_beacon_exception_name(void);
const char *dd_crash_beacon_exception_reason(void);
/// Records the beacon's result and releases the crashed thread.
void dd_crash_beacon_finish(DDCrashBeaconResult result, int32_t durationMs);

#ifdef __cplusplus
}
#endif

#endif /* DDCrashBeacon_h */
