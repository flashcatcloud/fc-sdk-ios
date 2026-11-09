/*
* Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
* This product includes software developed at Datadog (https://www.datadoghq.com/).
* Copyright 2019-Present Datadog, Inc.
*/

#include "DDTerminateHandler.h"

#include <stdlib.h>

typedef void (*DDTerminateFunction)(void);

DDTerminatePrelude _Nullable DDTakeoverTerminatePrelude = NULL;
DDTerminatePrelude _Nullable DDRecorderTerminatePrelude = NULL;

// `musttail` makes the call a jump that reuses this frame: the next handler returns, if ever, to the C++ runtime.

void DDTakeoverTerminateHandler(void) {
    DDTerminatePrelude prelude = DDTakeoverTerminatePrelude;
    DDTerminateFunction next = prelude != NULL ? (DDTerminateFunction)prelude() : NULL;
    if (next == NULL) {
        abort();
    }
    __attribute__((musttail)) return next();
}

void DDRecorderTerminateHandler(void) {
    DDTerminatePrelude prelude = DDRecorderTerminatePrelude;
    DDTerminateFunction next = prelude != NULL ? (DDTerminateFunction)prelude() : NULL;
    if (next == NULL) {
        abort();
    }
    __attribute__((musttail)) return next();
}
