/*
* Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
* This product includes software developed at Datadog (https://www.datadoghq.com/).
* Copyright 2019-Present Datadog, Inc.
*/

// FLASHCAT FORK - C++ terminate handlers that hand over to the next handler with a tail call.
//
// A terminate handler that calls the next one stays on the stack while that one runs. The crash
// reporter then records its frames above the C++ runtime's, and so does any other crash reporter in
// the app, some of which group crashes by their top frames: the throw site falls out of the grouping
// and the crash appears to come from this SDK. These handlers run a prelude written in Swift, which
// returns, and then jump to the handler the prelude names with a guaranteed tail call, so no frame of
// this SDK is left between the C++ runtime and the next handler.

#ifndef DDTerminateHandler_h
#define DDTerminateHandler_h

#ifdef __cplusplus
extern "C" {
#endif

/// Runs at the start of a terminate handler. Returns the terminate handler to hand over to, or NULL to abort.
typedef void * _Nullable (*DDTerminatePrelude)(void);

/// The terminate handler of the crash handler takeover, and its prelude.
void DDTakeoverTerminateHandler(void);
extern DDTerminatePrelude _Nullable DDTakeoverTerminatePrelude;

/// The terminate handler of the throw site recorder, and its prelude.
void DDRecorderTerminateHandler(void);
extern DDTerminatePrelude _Nullable DDRecorderTerminatePrelude;

#ifdef __cplusplus
}
#endif

#endif /* DDTerminateHandler_h */
