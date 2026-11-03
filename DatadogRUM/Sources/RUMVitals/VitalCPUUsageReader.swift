/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation
import DatadogInternal

// FLASHCAT FORK - the CPU usage reported as `view.cpu_usage_*` and `view.main_thread_cpu_usage_*`.
// Unlike `VitalCPUReader` (device-wide user ticks), it measures this process and its main thread,
// and turns the measures into percentages so they compare across devices with different core counts.

/// Cumulative values read at one point in time, with the time the app spent inactive taken out.
internal struct CPUUsageSample: Equatable {
    /// CPU time (user + system) used by all threads of the process, in seconds.
    let processCPUTime: TimeInterval
    /// CPU time (user + system) used by the main thread, in seconds.
    let mainThreadCPUTime: TimeInterval
    /// Wall-clock time, in seconds.
    let wallTime: TimeInterval

    static let zero = CPUUsageSample(processCPUTime: 0, mainThreadCPUTime: 0, wallTime: 0)

    static func + (lhs: CPUUsageSample, rhs: CPUUsageSample) -> CPUUsageSample {
        return CPUUsageSample(
            processCPUTime: lhs.processCPUTime + rhs.processCPUTime,
            mainThreadCPUTime: lhs.mainThreadCPUTime + rhs.mainThreadCPUTime,
            wallTime: lhs.wallTime + rhs.wallTime
        )
    }

    static func - (lhs: CPUUsageSample, rhs: CPUUsageSample) -> CPUUsageSample {
        return CPUUsageSample(
            processCPUTime: lhs.processCPUTime - rhs.processCPUTime,
            mainThreadCPUTime: lhs.mainThreadCPUTime - rhs.mainThreadCPUTime,
            wallTime: lhs.wallTime - rhs.wallTime
        )
    }
}

internal protocol CPUUsageReader: AnyObject {
    /// The number of cores the process CPU usage is divided by.
    var processorCount: Int { get }
    /// Reads the cumulative values, or `nil` if they can't be read.
    func readSample() -> CPUUsageSample?
}

/// Reads the CPU time of this process and of its main thread, skipping the periods the app is inactive.
///
/// The process CPU time comes from `getrusage(RUSAGE_SELF)`, which also counts threads that have already
/// exited. The main thread CPU time comes from `thread_info(THREAD_BASIC_INFO)` on the main thread's port.
internal class VitalCPUUsageReader: CPUUsageReader {
    let processorCount: Int
    /// Resolved on the first read from the main thread: the iOS SDK does not declare `pthread_main_thread_np()`.
    private var mainThreadPort: mach_port_t?
    private var totalInactive: CPUUsageSample = .zero
    private var rawSampleWhenResigningActive: CPUUsageSample? = nil
    private var hasReportedError = false
    /// Telemetry interface.
    private let telemetry: Telemetry

    init(
        notificationCenter: NotificationCenter,
        telemetry: Telemetry = NOPTelemetry(),
        processorCount: Int = ProcessInfo.processInfo.activeProcessorCount
    ) {
        self.processorCount = max(processorCount, 1)
        self.telemetry = telemetry
        notificationCenter.addObserver(self, selector: #selector(appWillResignActive), name: ApplicationNotifications.willResignActive, object: nil)
        notificationCenter.addObserver(self, selector: #selector(appDidBecomeActive), name: ApplicationNotifications.didBecomeActive, object: nil)
    }

    func readSample() -> CPUUsageSample? {
        guard let rawSample = readRawSample() else {
            return nil
        }
        let ongoingInactive = rawSampleWhenResigningActive.map { rawSample - $0 } ?? .zero
        return rawSample - totalInactive - ongoingInactive
    }

    // Like in `VitalCPUReader`, the notifications and `readSample()` are both delivered on the main thread.

    @objc
    private func appWillResignActive() {
        rawSampleWhenResigningActive = readRawSample()
    }

    @objc
    private func appDidBecomeActive() {
        if let previousRawSample = rawSampleWhenResigningActive,
           let currentRawSample = readRawSample() {
            rawSampleWhenResigningActive = nil
            totalInactive = totalInactive + (currentRawSample - previousRawSample)
        }
    }

    internal func readRawSample() -> CPUUsageSample? {
        guard let processCPUTime = readProcessCPUTime(),
              let mainThreadCPUTime = readMainThreadCPUTime() else {
            return nil
        }
        return CPUUsageSample(
            processCPUTime: processCPUTime,
            mainThreadCPUTime: mainThreadCPUTime,
            wallTime: ProcessInfo.processInfo.systemUptime
        )
    }

    private func readProcessCPUTime() -> TimeInterval? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            reportError("CPU usage cannot be read! getrusage errno: \(errno)")
            return nil
        }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private func readMainThreadCPUTime() -> TimeInterval? {
        if mainThreadPort == nil && Thread.isMainThread {
            mainThreadPort = pthread_mach_thread_np(pthread_self())
        }
        guard let mainThreadPort = mainThreadPort else {
            return nil
        }
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { integerPtr in
                thread_info(mainThreadPort, thread_flavor_t(THREAD_BASIC_INFO), integerPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            reportError("Main thread CPU usage cannot be read! Error code: \(result)")
            return nil
        }
        return seconds(info.user_time) + seconds(info.system_time)
    }

    /// Reports the first failure only: the timer reads every vitals interval, so a lasting failure would repeat.
    private func reportError(_ message: String) {
        guard !hasReportedError else {
            return
        }
        hasReportedError = true
        telemetry.error(message)
    }
}

/// Aggregates the samples taken while a view is displayed into the four values reported on the view.
internal struct CPUUsageInfo {
    /// The view needs this much foreground time before any value is reported; `cpu_ticks_per_second` follows the same rule.
    static let minimumForegroundTime: TimeInterval = 1.0
    /// Peaks are computed over intervals at least this long, so a very short interval does not amplify noise.
    static let minimumPeakInterval: TimeInterval = 0.25

    let processorCount: Int
    private(set) var firstSample: CPUUsageSample?
    private(set) var lastSample: CPUUsageSample?
    private var peakIntervalStart: CPUUsageSample?
    private var processIntervalPeak: Double?
    private var mainThreadIntervalPeak: Double?

    init(processorCount: Int) {
        self.processorCount = max(processorCount, 1)
    }

    mutating func addSample(_ sample: CPUUsageSample) {
        lastSample = sample
        guard firstSample != nil, let intervalStart = peakIntervalStart else {
            firstSample = sample
            peakIntervalStart = sample
            return
        }
        let interval = sample - intervalStart
        guard interval.wallTime >= Self.minimumPeakInterval else {
            return
        }
        peakIntervalStart = sample
        if let usage = processUsage(over: interval) {
            processIntervalPeak = max(processIntervalPeak ?? 0, usage)
        }
        if let usage = mainThreadUsage(over: interval) {
            mainThreadIntervalPeak = max(mainThreadIntervalPeak ?? 0, usage)
        }
    }

    /// Process CPU usage over the view, as a percentage of all cores (0-100).
    var processUsageAverage: Double? {
        return viewTotal.flatMap { processUsage(over: $0) }
    }

    /// Main thread CPU usage over the view, as a percentage of one core (0-100).
    var mainThreadUsageAverage: Double? {
        return viewTotal.flatMap { mainThreadUsage(over: $0) }
    }

    // A trailing interval shorter than `minimumPeakInterval` counts in the average but not in the peaks,
    // so a busy tail could put the average above the peak. The average over the whole view is never above
    // the real peak, so it is a safe lower bound.

    /// Process CPU usage peak over the view, as a percentage of all cores (0-100).
    var processUsageMax: Double? {
        return [processIntervalPeak, processUsageAverage].compactMap { $0 }.max()
    }

    /// Main thread CPU usage peak over the view, as a percentage of one core (0-100).
    var mainThreadUsageMax: Double? {
        return [mainThreadIntervalPeak, mainThreadUsageAverage].compactMap { $0 }.max()
    }

    /// Whether the view has been in foreground long enough to report any value.
    var hasEnoughForegroundTime: Bool {
        return (viewTotal?.wallTime ?? 0) > Self.minimumForegroundTime
    }

    private var viewTotal: CPUUsageSample? {
        guard let first = firstSample, let last = lastSample else {
            return nil
        }
        return last - first
    }

    private func processUsage(over interval: CPUUsageSample) -> Double? {
        return percentage(interval.processCPUTime, of: interval.wallTime * Double(processorCount))
    }

    private func mainThreadUsage(over interval: CPUUsageSample) -> Double? {
        return percentage(interval.mainThreadCPUTime, of: interval.wallTime)
    }

    private func percentage(_ cpuTime: TimeInterval, of capacity: TimeInterval) -> Double? {
        guard capacity > 0 else {
            return nil
        }
        return min(max(cpuTime / capacity * 100, 0), 100)
    }
}

private func seconds(_ value: timeval) -> TimeInterval {
    return TimeInterval(value.tv_sec) + TimeInterval(value.tv_usec) / 1_000_000
}

private func seconds(_ value: time_value_t) -> TimeInterval {
    return TimeInterval(value.seconds) + TimeInterval(value.microseconds) / 1_000_000
}
