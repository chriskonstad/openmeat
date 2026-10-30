import Charts
import CookCore
import SwiftUI

/// Interactive multi-probe chart (SPEC §7.2):
/// - drag to pan, pinch to zoom time, double-tap to toggle "fit all" / "last 30 min"
/// - long-press-drag to scrub with a crosshair showing every series' value
/// - follows "now" while scrolled to the live edge; "Jump to live" when panned away
/// - target rules, ETA projection, note markers, legend chips toggle series
struct CookChartView: View {
    let cook: Cook
    let estimates: [ChannelKey: Estimate]
    let unit: TemperatureUnit
    let now: Date
    let isLive: Bool

    @State private var hidden: Set<ChannelKey> = []
    @State private var visibleLength: TimeInterval = 30 * 60
    @State private var scrollPosition: Date = .distantPast
    @State private var selectedTime: Date?
    @State private var pinchBase: TimeInterval?

    private var start: Date { cook.startedAt }
    private var end: Date { max(cook.endedAt ?? now, start.addingTimeInterval(60)) }
    private var duration: TimeInterval { end.timeIntervalSince(start) }
    private var effectiveLength: TimeInterval { ChartSeriesBuilder.clampVisibleLength(visibleLength, cookDuration: duration) }
    private var liveEdge: Date { max(start, end.addingTimeInterval(-effectiveLength)) }
    private var isAtLiveEdge: Bool { scrollPosition >= liveEdge.addingTimeInterval(-effectiveLength * 0.05) }

    private var series: [ChartSeries] {
        // Downsample over the visible window with margin so panning stays smooth.
        let margin = effectiveLength
        let window = scrollPosition.addingTimeInterval(-margin)...scrollPosition.addingTimeInterval(effectiveLength + margin)
        return ChartSeriesBuilder.series(for: cook, unit: unit, hidden: hidden, window: window, maxPointsPerSeries: 400)
    }

    var body: some View {
        let series = series
        VStack(alignment: .leading, spacing: 8) {
            chart(series)
            legend
        }
        .onAppear {
            visibleLength = isLive ? 30 * 60 : duration
            scrollPosition = liveEdge
        }
        .onChange(of: now) { oldNow, _ in
            // Follow live if the user was at the live edge before this update.
            let previousEdge = max(start, max(cook.endedAt ?? oldNow, start.addingTimeInterval(60)).addingTimeInterval(-effectiveLength))
            if isLive, scrollPosition >= previousEdge.addingTimeInterval(-effectiveLength * 0.05) {
                scrollPosition = liveEdge
            }
        }
    }

    private func chart(_ series: [ChartSeries]) -> some View {
        Chart {
            ForEach(series) { s in
                ForEach(s.points) { p in
                    LineMark(x: .value("Time", p.time), y: .value("Temperature", p.value), series: .value("Probe", s.key.description))
                        .foregroundStyle(ProbePalette.color(s.colorIndex).opacity(s.role == .ambient ? 0.6 : 1))
                        .lineStyle(s.role == .ambient ? StrokeStyle(lineWidth: 1.5, dash: [5, 4]) : StrokeStyle(lineWidth: 2.5))
                        .interpolationMethod(.monotone)
                }
                if s.role == .internal, let target = s.target {
                    RuleMark(y: .value("Target", target))
                        .foregroundStyle(ProbePalette.color(s.colorIndex).opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("\(s.label) \(Int(target.rounded()))°").font(.caption2).foregroundStyle(.secondary)
                        }
                    // ETA projection: straight dashed segment from the latest reading to (ETA, target).
                    // TODO(M4): draw the fitted Newton curve with an uncertainty band.
                    if isLive, let last = s.points.last, let eta = estimates[s.key]?.eta, estimates[s.key]?.state == .estimating {
                        ForEach([ChartPoint(time: last.time, value: last.value), ChartPoint(time: eta, value: target)]) { p in
                            LineMark(x: .value("Time", p.time), y: .value("Temperature", p.value), series: .value("Projection", "proj-\(s.key)"))
                                .foregroundStyle(ProbePalette.color(s.colorIndex).opacity(0.4))
                                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [1, 4]))
                        }
                    }
                }
            }
            ForEach(cook.notes) { note in
                RuleMark(x: .value("Note", note.time))
                    .foregroundStyle(.secondary.opacity(0.35))
                    .annotation(position: .bottom, alignment: .center, spacing: 0) {
                        Image(systemName: "note.text").font(.caption2).foregroundStyle(.secondary)
                            .accessibilityLabel("Note: \(note.text)")
                    }
            }
            if let selectedTime {
                RuleMark(x: .value("Selected", selectedTime))
                    .foregroundStyle(.primary.opacity(0.4))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        scrubTooltip(at: selectedTime, series: series)
                    }
            }
        }
        .chartYScale(domain: ChartSeriesBuilder.yDomain(series))
        .chartXScale(domain: start...max(end, start.addingTimeInterval(effectiveLength)))
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: effectiveLength)
        .chartScrollPosition(x: $scrollPosition)
        .chartXSelection(value: $selectedTime)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) {
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .chartYAxisLabel(unit.symbol)
        .chartLegend(.hidden)
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    let base = pinchBase ?? effectiveLength
                    pinchBase = base
                    visibleLength = ChartSeriesBuilder.clampVisibleLength(base / value.magnification, cookDuration: duration)
                }
                .onEnded { _ in pinchBase = nil }
        )
        .onTapGesture(count: 2) {
            visibleLength = effectiveLength >= duration * 0.95 ? 30 * 60 : duration
            scrollPosition = liveEdge
        }
        .overlay(alignment: .topTrailing) {
            if isLive, !isAtLiveEdge {
                Button("Live", systemImage: "forward.end.fill") { scrollPosition = liveEdge }
                    .font(.caption.bold())
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(AccessibilityID.Live.jumpToLive)
            }
        }
    }

    private func scrubTooltip(at time: Date, series: [ChartSeries]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(time.formatted(date: .omitted, time: .shortened)) · +\(Formatting.duration(time.timeIntervalSince(start)))")
                .font(.caption2.bold())
            ForEach(series) { s in
                if let v = ChartSeriesBuilder.value(at: time, in: s) {
                    HStack(spacing: 4) {
                        Circle().fill(ProbePalette.color(s.colorIndex)).frame(width: 6, height: 6)
                        Text("\(s.label): \(v.formatted(.number.precision(.fractionLength(1))))°").font(.caption2.monospacedDigit())
                    }
                }
            }
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var legend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(cook.probes) { probe in
                    let isHidden = hidden.contains(probe.key)
                    Button {
                        if isHidden { hidden.remove(probe.key) } else { hidden.insert(probe.key) }
                    } label: {
                        HStack(spacing: 4) {
                            Circle().fill(ProbePalette.color(probe.colorIndex).opacity(isHidden ? 0.25 : 1)).frame(width: 8, height: 8)
                            Text(probe.label).font(.caption).strikethrough(isHidden)
                        }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier(AccessibilityID.Live.legendChip(probe.key.description))
                    .accessibilityValue(isHidden ? "hidden" : "shown")
                }
            }
        }
    }
}
