/*
* Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
* This product includes software developed at Datadog (https://www.datadoghq.com/).
* Copyright 2019-Present Datadog, Inc.
*/

#import <Foundation/Foundation.h>
#import "DDCrashBeacon.h"

#include <errno.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <poll.h>
#include <signal.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

// The fatal signals KSCrash 2.5 handles, minus SIGTERM: a SIGTERM is the system ending the process,
// not a crash, and KSCrash writes no report for it.
static const int kSignals[] = { SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGPIPE, SIGSEGV, SIGSYS, SIGTRAP };
#define SIGNAL_COUNT ((int)(sizeof(kSignals) / sizeof(kSignals[0])))

static struct sigaction g_previous[SIGNAL_COUNT];
static bool g_installedOn[SIGNAL_COUNT];
static atomic_flag g_installed = ATOMIC_FLAG_INIT;

static int g_wakePipe[2] = { -1, -1 };
static int g_ackPipe[2] = { -1, -1 };

static atomic_bool g_armed = false;
static atomic_bool g_foreground = false;
static atomic_int g_timeoutMs = 1000;
static atomic_flag g_fired = ATOMIC_FLAG_INIT;

static char g_resultPath[1024];
static char g_crashId[DDCrashBeaconIdLength + 1];

static NSUncaughtExceptionHandler *g_previousExceptionHandler;
static char g_exceptionName[128];
static char g_exceptionReason[256];

static mach_timebase_info_data_t *timebase(void)
{
    static mach_timebase_info_data_t value;
    return &value;
}

static int64_t elapsedMs(uint64_t since)
{
    mach_timebase_info_data_t *tb = timebase();
    return (int64_t)((mach_absolute_time() - since) * tb->numer / tb->denom / 1000000);
}

/// Async-signal-safe: open, write and close only.
static void recordResult(DDCrashBeaconResult result, int32_t durationMs)
{
    if (g_resultPath[0] == '\0') {
        return;
    }
    unsigned char record[DDCrashBeaconRecordSize] = { 0 };
    record[0] = (unsigned char)result;
    record[1] = (unsigned char)(durationMs & 0xff);
    record[2] = (unsigned char)((durationMs >> 8) & 0xff);
    record[3] = (unsigned char)((durationMs >> 16) & 0xff);
    record[4] = (unsigned char)((durationMs >> 24) & 0xff);
    memcpy(record + 5, g_crashId, DDCrashBeaconIdLength);

    int fd = open(g_resultPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        return;
    }
    write(fd, record, sizeof(record));
    close(fd);
}

static void waitForBeacon(int sigNum)
{
    if (!atomic_load(&g_armed) || !atomic_load(&g_foreground)) {
        recordResult(DDCrashBeaconResultSkipped, 0);
        return;
    }

    unsigned char byte = (unsigned char)sigNum;
    if (write(g_wakePipe[1], &byte, 1) != 1) {
        recordResult(DDCrashBeaconResultFailed, 0);
        return;
    }

    const int32_t timeoutMs = atomic_load(&g_timeoutMs);
    const uint64_t start = mach_absolute_time();
    struct pollfd ack = { .fd = g_ackPipe[0], .events = POLLIN, .revents = 0 };
    for (;;) {
        int64_t remaining = timeoutMs - elapsedMs(start);
        int ready = remaining > 0 ? poll(&ack, 1, (int)remaining) : 0;
        if (ready < 0 && errno == EINTR) {
            continue;
        }
        if (ready == 0) {
            // The beacon thread did not answer in time: a slow network, or a lock this thread
            // holds (malloc, dyld). It cannot record anything itself, so record it here.
            recordResult(DDCrashBeaconResultTimeout, timeoutMs);
        }
        return;
    }
}

void dd_crash_beacon_handle_crash(int sigNum)
{
    // Only the first fatal signal waits. Another one (a second thread, or the beacon thread
    // crashing itself) goes straight through.
    if (!atomic_flag_test_and_set(&g_fired)) {
        waitForBeacon(sigNum);
    }
}

static void handleSignal(int sigNum, siginfo_t *info, void *userContext)
{
    (void)info;
    (void)userContext;
    int savedErrno = errno;

    dd_crash_beacon_handle_crash(sigNum);

    for (int i = 0; i < SIGNAL_COUNT; i++) {
        if (kSignals[i] == sigNum && g_installedOn[i]) {
            sigaction(sigNum, &g_previous[i], NULL);
            break;
        }
    }
    errno = savedErrno;
    raise(sigNum);
}

/// Runs in ordinary code before KSCrash's own hook calls it: only keeps the name and reason, which
/// the signal that follows (SIGABRT) does not carry.
static void handleUncaughtException(NSException *exception)
{
    strlcpy(g_exceptionName, exception.name.UTF8String ?: "", sizeof(g_exceptionName));
    strlcpy(g_exceptionReason, exception.reason.UTF8String ?: "", sizeof(g_exceptionReason));
    if (g_previousExceptionHandler != NULL) {
        g_previousExceptionHandler(exception);
    }
}

static bool isBeingTraced(void)
{
    struct kinfo_proc info;
    size_t size = sizeof(info);
    int mib[] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    if (sysctl(mib, sizeof(mib) / sizeof(*mib), &info, &size, NULL, 0) != 0) {
        return false;
    }
    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

bool dd_crash_beacon_install(const char *resultPath, const char *crashId)
{
    if (isBeingTraced() || atomic_flag_test_and_set(&g_installed)) {
        return false;
    }

    mach_timebase_info(timebase());
    strlcpy(g_resultPath, resultPath ?: "", sizeof(g_resultPath));
    strlcpy(g_crashId, crashId ?: "", sizeof(g_crashId));

    if (pipe(g_wakePipe) != 0 || pipe(g_ackPipe) != 0) {
        return false;
    }
    // Writers never block: the crashed thread must not wait on a full pipe.
    fcntl(g_wakePipe[1], F_SETFL, O_NONBLOCK);
    fcntl(g_ackPipe[1], F_SETFL, O_NONBLOCK);

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_flags = SA_SIGINFO | SA_ONSTACK;
#if defined(__LP64__)
    action.sa_flags |= SA_64REGSET;
#endif
    sigemptyset(&action.sa_mask);
    action.sa_sigaction = &handleSignal;

    for (int i = 0; i < SIGNAL_COUNT; i++) {
        struct sigaction current;
        if (sigaction(kSignals[i], NULL, &current) != 0) {
            continue;
        }
        // Leave an ignored signal ignored (apps commonly ignore SIGPIPE).
        if (!(current.sa_flags & SA_SIGINFO) && current.sa_handler == SIG_IGN) {
            continue;
        }
        if (sigaction(kSignals[i], &action, &g_previous[i]) == 0) {
            g_installedOn[i] = true;
        }
    }

    g_previousExceptionHandler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(&handleUncaughtException);
    return true;
}

void dd_crash_beacon_set_armed(bool armed) { atomic_store(&g_armed, armed); }

void dd_crash_beacon_set_foreground(bool foreground) { atomic_store(&g_foreground, foreground); }

void dd_crash_beacon_set_timeout_ms(int32_t timeoutMs)
{
    if (timeoutMs < 500) {
        timeoutMs = 500;
    }
    if (timeoutMs > 2000) {
        timeoutMs = 2000;
    }
    atomic_store(&g_timeoutMs, timeoutMs);
}

int32_t dd_crash_beacon_timeout_ms(void) { return atomic_load(&g_timeoutMs); }

int dd_crash_beacon_wait_for_wake(void)
{
    unsigned char byte = 0;
    for (;;) {
        ssize_t n = read(g_wakePipe[0], &byte, 1);
        if (n == 1) {
            return byte;
        }
        if (n < 0 && errno == EINTR) {
            continue;
        }
        return -1;
    }
}

const char *dd_crash_beacon_exception_name(void) { return g_exceptionName; }

const char *dd_crash_beacon_exception_reason(void) { return g_exceptionReason; }

void dd_crash_beacon_finish(DDCrashBeaconResult result, int32_t durationMs)
{
    recordResult(result, durationMs);
    unsigned char byte = 1;
    write(g_ackPipe[1], &byte, 1);
}
