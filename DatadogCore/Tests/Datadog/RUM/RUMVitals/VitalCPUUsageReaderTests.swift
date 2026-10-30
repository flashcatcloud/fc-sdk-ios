/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import XCTest
import UIKit.UIApplication
import TestUtilities
@testable import DatadogRUM

class VitalCPUUsageReaderTests: XCTestCase {
    let testNotificationCenter = NotificationCenter()

    // MARK: - Reader

    func testItReadsIncreasingValues() throws {
        let reader = VitalCPUUsageReader(notificationCenter: testNotificationCenter)

        let first = try XCTUnwrap(reader.readSample())
        busyLoop(for: 0.2)
        let second = try XCTUnwrap(reader.readSample())

        XCTAssertGreaterThan(second.processCPUTime, first.processCPUTime)
        XCTAssertGreaterThan(second.wallTime, first.wallTime)
        XCTAssertGreaterThanOrEqual(second.mainThreadCPUTime, first.mainThreadCPUTime)
    }

    func testWhenMainThreadIsBusyItMeasuresMainThreadCPUTime() throws {
        XCTAssertTrue(Thread.isMainThread)
        let reader = VitalCPUUsageReader(notificationCenter: testNotificationCenter)

        let first = try XCTUnwrap(reader.readSample())
        busyLoop(for: 0.5)
        let second = try XCTUnwrap(reader.readSample())

        // Half of the busy time: on a loaded simulator host the main thread can be preempted for ~40% of it.
        XCTAssertGreaterThan(second.mainThreadCPUTime - first.mainThreadCPUTime, 0.25)
        XCTAssertGreaterThanOrEqual(
            second.processCPUTime - first.processCPUTime,
            second.mainThreadCPUTime - first.mainThreadCPUTime - 0.05
        )
    }

    func testWhenBackgroundThreadIsBusyItCountsProcessButNotMainThread() throws {
        let reader = VitalCPUUsageReader(notificationCenter: testNotificationCenter)

        let first = try XCTUnwrap(reader.readSample())
        let done = expectation(description: "background work done")
        DispatchQueue.global(qos: .userInitiated).async {
            busyLoop(for: 0.5)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        let second = try XCTUnwrap(reader.readSample())

        XCTAssertGreaterThan(second.processCPUTime - first.processCPUTime, 0.3)
        XCTAssertLessThan(second.mainThreadCPUTime - first.mainThreadCPUTime, 0.2)
    }

    func testWhenAppIsInactiveItSkipsInactivePeriod() throws {
        let reader = VitalCPUUsageReaderMock(
            notificationCenter: testNotificationCenter,
            rawSamples: [
                .init(processCPUTime: 10, mainThreadCPUTime: 5, wallTime: 100), // first read
                .init(processCPUTime: 11, mainThreadCPUTime: 6, wallTime: 102), // will resign active
                .init(processCPUTime: 15, mainThreadCPUTime: 6, wallTime: 130), // read while inactive
                .init(processCPUTime: 20, mainThreadCPUTime: 6, wallTime: 160), // did become active
                .init(processCPUTime: 21, mainThreadCPUTime: 7, wallTime: 162), // read when active again
            ]
        )

        let first = try XCTUnwrap(reader.readSample())
        testNotificationCenter.post(name: UIApplication.willResignActiveNotification, object: nil)
        let whileInactive = try XCTUnwrap(reader.readSample())
        testNotificationCenter.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        let afterInactive = try XCTUnwrap(reader.readSample())

        XCTAssertEqual(whileInactive - first, .init(processCPUTime: 1, mainThreadCPUTime: 1, wallTime: 2))
        XCTAssertEqual(afterInactive - first, .init(processCPUTime: 2, mainThreadCPUTime: 2, wallTime: 4))
    }

    func testWhenValuesCannotBeReadItReturnsNil() {
        let reader = VitalCPUUsageReaderMock(notificationCenter: testNotificationCenter, rawSamples: [])
        XCTAssertNil(reader.readSample())
    }

    // MARK: - Aggregation

    func testItReportsProcessUsageAsPercentageOfAllCores() throws {
        var info = CPUUsageInfo(processorCount: 4)
        info.addSample(.init(processCPUTime: 0, mainThreadCPUTime: 0, wallTime: 0))
        info.addSample(.init(processCPUTime: 4, mainThreadCPUTime: 1, wallTime: 2))

        XCTAssertTrue(info.hasEnoughForegroundTime)
        XCTAssertEqual(try XCTUnwrap(info.processUsageAverage), 50, accuracy: 0.001) // 4s / (2s * 4 cores)
        XCTAssertEqual(try XCTUnwrap(info.mainThreadUsageAverage), 50, accuracy: 0.001) // 1s / 2s
    }

    func testItReportsPeaksOverSampleIntervals() throws {
        var info = CPUUsageInfo(processorCount: 2)
        info.addSample(.init(processCPUTime: 0, mainThreadCPUTime: 0, wallTime: 0))
        info.addSample(.init(processCPUTime: 0.2, mainThreadCPUTime: 0.1, wallTime: 0.5)) // 20%, 20%
        info.addSample(.init(processCPUTime: 1.0, mainThreadCPUTime: 0.55, wallTime: 1.0)) // 80%, 90%
        info.addSample(.init(processCPUTime: 1.1, mainThreadCPUTime: 0.6, wallTime: 1.5)) // 10%, 10%

        XCTAssertEqual(try XCTUnwrap(info.processUsageMax), 80, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(info.mainThreadUsageMax), 90, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(info.processUsageAverage), 1.1 / 3 * 100, accuracy: 0.001)
    }

    func testItMergesIntervalsShorterThanMinimumIntoPeaks() throws {
        var info = CPUUsageInfo(processorCount: 1)
        info.addSample(.init(processCPUTime: 0, mainThreadCPUTime: 0, wallTime: 0))
        info.addSample(.init(processCPUTime: 0.01, mainThreadCPUTime: 0.01, wallTime: 0.01)) // too short on its own
        info.addSample(.init(processCPUTime: 0.15, mainThreadCPUTime: 0.05, wallTime: 0.3))

        XCTAssertEqual(try XCTUnwrap(info.processUsageMax), 50, accuracy: 0.001) // 0.15s / 0.3s
        XCTAssertEqual(try XCTUnwrap(info.mainThreadUsageMax), 0.05 / 0.3 * 100, accuracy: 0.001)
    }

    func testWhenTheTrailingIntervalIsBusiestThePeakIsNotBelowTheAverage() throws {
        var info = CPUUsageInfo(processorCount: 1)
        info.addSample(.init(processCPUTime: 0, mainThreadCPUTime: 0, wallTime: 0))
        info.addSample(.init(processCPUTime: 0.03, mainThreadCPUTime: 0.03, wallTime: 0.3)) // 10%
        info.addSample(.init(processCPUTime: 0.06, mainThreadCPUTime: 0.06, wallTime: 0.6)) // 10%
        info.addSample(.init(processCPUTime: 0.09, mainThreadCPUTime: 0.09, wallTime: 0.9)) // 10%
        info.addSample(.init(processCPUTime: 0.29, mainThreadCPUTime: 0.29, wallTime: 1.1)) // 100%, but only 0.2s

        let processAverage = try XCTUnwrap(info.processUsageAverage)
        let mainThreadAverage = try XCTUnwrap(info.mainThreadUsageAverage)
        XCTAssertEqual(processAverage, 0.29 / 1.1 * 100, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(info.processUsageMax), processAverage, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(info.mainThreadUsageMax), mainThreadAverage, accuracy: 0.001)
    }

    func testItClampsValuesBetween0And100() {
        var info = CPUUsageInfo(processorCount: 1)
        info.addSample(.init(processCPUTime: 0, mainThreadCPUTime: 0, wallTime: 0))
        info.addSample(.init(processCPUTime: 3, mainThreadCPUTime: 3, wallTime: 2))

        XCTAssertEqual(info.processUsageAverage, 100)
        XCTAssertEqual(info.mainThreadUsageAverage, 100)
    }

    func testWhenForegroundTimeIsTooShortItHasNotEnoughTime() {
        var info = CPUUsageInfo(processorCount: 4)
        XCTAssertFalse(info.hasEnoughForegroundTime)
        XCTAssertNil(info.processUsageAverage)

        info.addSample(.init(processCPUTime: 0, mainThreadCPUTime: 0, wallTime: 10))
        info.addSample(.init(processCPUTime: 0.5, mainThreadCPUTime: 0.5, wallTime: 11))

        XCTAssertFalse(info.hasEnoughForegroundTime)
    }

    func testWhenProcessorCountIsZeroItUsesOneCore() {
        var info = CPUUsageInfo(processorCount: 0)
        info.addSample(.init(processCPUTime: 0, mainThreadCPUTime: 0, wallTime: 0))
        info.addSample(.init(processCPUTime: 1, mainThreadCPUTime: 0, wallTime: 2))

        XCTAssertEqual(info.processUsageAverage, 50)
    }

    // MARK: - Sampling

    func testVitalInfoSamplerAggregatesCPUUsageSamples() {
        let reader = CPUUsageReaderMock(processorCount: 2)
        reader.samples = [
            .init(processCPUTime: 0, mainThreadCPUTime: 0, wallTime: 0),
            .init(processCPUTime: 2, mainThreadCPUTime: 1, wallTime: 2),
        ]

        let sampler = VitalInfoSampler(
            cpuReader: SamplingBasedVitalReaderMock(),
            memoryReader: SamplingBasedVitalReaderMock(),
            refreshRateReader: ContinuousVitalReaderMock(),
            cpuUsageReader: reader,
            frequency: 0.1
        )

        let samplingExpectation = expectation(description: "sampling expectation")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            samplingExpectation.fulfill()
        }

        waitForExpectations(timeout: 1.0) { _ in
            let info = sampler.cpuUsage
            XCTAssertEqual(info?.processUsageAverage, 50)
            XCTAssertEqual(info?.mainThreadUsageAverage, 50)
        }
    }

    func testVitalInfoSamplerWithoutCPUUsageReaderHasNoCPUUsage() {
        let sampler = VitalInfoSampler(
            cpuReader: SamplingBasedVitalReaderMock(),
            memoryReader: SamplingBasedVitalReaderMock(),
            refreshRateReader: ContinuousVitalReaderMock(),
            frequency: 0.1
        )
        XCTAssertNil(sampler.cpuUsage)
    }
}

// Overrides only the OS reads; inactive period accounting stays in VitalCPUUsageReader.
private class VitalCPUUsageReaderMock: VitalCPUUsageReader {
    private var rawSamples: [CPUUsageSample]

    init(notificationCenter: NotificationCenter, rawSamples: [CPUUsageSample]) {
        self.rawSamples = rawSamples
        super.init(notificationCenter: notificationCenter, processorCount: 1)
    }

    override func readRawSample() -> CPUUsageSample? {
        rawSamples.isEmpty ? nil : rawSamples.removeFirst()
    }
}

/// Returns the given samples in order, then keeps returning the last one.
private class CPUUsageReaderMock: CPUUsageReader {
    let processorCount: Int
    var samples: [CPUUsageSample] = []

    init(processorCount: Int) {
        self.processorCount = processorCount
    }

    func readSample() -> CPUUsageSample? {
        samples.count > 1 ? samples.removeFirst() : samples.first
    }
}

private func busyLoop(for duration: TimeInterval) {
    let start = Date()
    var value = 0.0
    while Date().timeIntervalSince(start) < duration {
        for i in 0..<10_000 {
            value += sqrt(Double(i))
        }
    }
    XCTAssertGreaterThan(value, 0)
}
