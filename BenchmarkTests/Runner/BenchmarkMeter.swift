/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation
import FlashcatInternal
import DatadogBenchmarks
import OpenTelemetryApi

internal final class Meter: FlashcatInternal.BenchmarkMeter {
    let meter: OpenTelemetryApi.Meter

    init(provider: MeterProvider) {
        self.meter = provider.get(
            instrumentationName: "benchmarks",
            instrumentationVersion: nil
        )
    }

    func counter(metric: @autoclosure () -> String) -> FlashcatInternal.BenchmarkCounter {
        meter.createDoubleCounter(name: metric())
    }

    func gauge(metric: @autoclosure () -> String) -> FlashcatInternal.BenchmarkGauge {
        meter.createDoubleMeasure(name: metric())
    }

    func observe(metric: @autoclosure () -> String, callback: @escaping (any FlashcatInternal.BenchmarkGauge) -> Void) {
        _ = meter.createDoubleObserver(name: metric()) { callback(DoubleObserverWrapper(observer: $0)) }
    }
}

extension AnyCounterMetric<Double>: FlashcatInternal.BenchmarkCounter {
    public func add(value: Double, attributes: @autoclosure () -> [String: String]) {
        add(value: value, labelset: LabelSet(labels: attributes()))
    }
}

extension AnyMeasureMetric<Double>: FlashcatInternal.BenchmarkGauge {
    public func record(value: Double, attributes: @autoclosure () -> [String: String]) {
        record(value: value, labelset: LabelSet(labels: attributes()))
    }
}

private struct DoubleObserverWrapper: FlashcatInternal.BenchmarkGauge {
    let observer: DoubleObserverMetric

    func record(value: Double, attributes: @autoclosure () -> [String: String]) {
        observer.observe(value: value, labelset: LabelSet(labels: attributes()))
    }
}
