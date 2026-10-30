import CookCore
import Foundation

struct ChartPoint: Identifiable, Hashable {
    var id: Date { time }
    var time: Date
    /// In the display unit.
    var value: Double
}

struct ChartSeries: Identifiable, Hashable {
    var id: ChannelKey { key }
    var key: ChannelKey
    var label: String
    var role: ProbeRole
    var colorIndex: Int
    var target: Double?
    var points: [ChartPoint]
}

/// Pure chart data preparation (downsampling, visibility, scrub lookups). Unit tested.
enum ChartSeriesBuilder {
    /// Series for visible probes, LTTB-downsampled to `maxPointsPerSeries` within `window` (plus one
    /// point either side so lines run to the edges).
    static func series(for cook: Cook, unit: TemperatureUnit, hidden: Set<ChannelKey> = [],
                       window: ClosedRange<Date>? = nil, maxPointsPerSeries: Int = 600) -> [ChartSeries] {
        cook.probes.filter { !hidden.contains($0.key) }.map { probe in
            var samples = cook.series[probe.key] ?? []
            if let window {
                let lower = samples.lastIndex { $0.time < window.lowerBound } ?? samples.startIndex
                let upper = samples.firstIndex { $0.time > window.upperBound }.map { $0 + 1 } ?? samples.endIndex
                samples = lower < upper ? Array(samples[lower..<upper]) : []
            }
            let reduced = LTTB.downsample(samples, to: maxPointsPerSeries)
            return ChartSeries(
                key: probe.key, label: probe.label, role: probe.role, colorIndex: probe.colorIndex,
                target: probe.target?.value(in: unit),
                points: reduced.map { ChartPoint(time: $0.time, value: $0.temperature.value(in: unit)) })
        }
    }

    /// Most recent value at or before `time` (for the scrub tooltip), or nil if before the first point.
    static func value(at time: Date, in series: ChartSeries) -> Double? {
        let points = series.points
        var low = 0, high = points.count - 1, found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if points[mid].time <= time {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found.map { points[$0].value }
    }

    /// Full-resolution lookup: most recent sample at or before `time`.
    static func sample(at time: Date, in samples: [Sample]) -> Sample? {
        var low = 0, high = samples.count - 1, found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if samples[mid].time <= time {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found.map { samples[$0] }
    }

    /// Tick spacing giving ~4–6 labels across the visible window.
    static func tickStride(visibleLength: TimeInterval) -> TimeInterval {
        let candidates: [TimeInterval] = [5, 10, 15, 30, 60, 120, 180, 240, 360, 720].map { $0 * 60 }
        return candidates.first { visibleLength / $0 <= 6 } ?? candidates.last!
    }

    /// Tick dates across the whole scrollable domain. Clock mode aligns to round clock times
    /// (10:00, 10:15…); elapsed mode aligns to the cook start (+0, +15m…).
    static func axisTicks(from start: Date, to end: Date, visibleLength: TimeInterval, alignedToStart: Bool,
                          calendar: Calendar = .current) -> [Date] {
        guard end > start else { return [] }
        let stride = tickStride(visibleLength: visibleLength)
        var first: Date
        if alignedToStart {
            first = start
        } else {
            // Align to multiples of the stride within the local day.
            let dayStart = calendar.startOfDay(for: start)
            let offset = start.timeIntervalSince(dayStart)
            first = dayStart.addingTimeInterval((offset / stride).rounded(.up) * stride)
        }
        var ticks: [Date] = []
        while first <= end, ticks.count < 2_000 {
            ticks.append(first)
            first = first.addingTimeInterval(stride)
        }
        return ticks
    }

    /// Y domain covering visible values and targets, padded, never narrower than `minimumSpan`.
    static func yDomain(_ series: [ChartSeries], minimumSpan: Double = 20) -> ClosedRange<Double> {
        let values = series.flatMap { $0.points.map(\.value) + ($0.target.map { [$0] } ?? []) }
        guard let lo = values.min(), let hi = values.max() else { return 0...100 }
        let pad = max((hi - lo) * 0.08, 2)
        var domain = (lo - pad)...(hi + pad)
        if domain.upperBound - domain.lowerBound < minimumSpan {
            let mid = (lo + hi) / 2
            domain = (mid - minimumSpan / 2)...(mid + minimumSpan / 2)
        }
        return domain
    }

    /// Clamps a requested visible length (seconds) to [10 min, whole cook].
    static func clampVisibleLength(_ length: TimeInterval, cookDuration: TimeInterval) -> TimeInterval {
        let maxLength = max(cookDuration, 10 * 60)
        return min(max(length, 10 * 60), maxLength)
    }
}
