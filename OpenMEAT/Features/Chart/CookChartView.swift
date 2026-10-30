import Charts
import CookCore
import SwiftUI

/// Interactive multi-probe chart (SPEC §7.2):
/// - a readout above the plot shows every series' current value — or its value at the scrubbed
///   time — and doubles as the legend; tap an item to hide/show that series
/// - drag to pan, pinch to zoom time, double-tap to toggle "whole cook" / "last 30 min"
/// - long-press-drag to scrub
/// - follows "now" until you pan away; "Live" jumps back
/// - clock or elapsed-time axis with aligned, unclipped labels
/// - target rules, ETA projection, note markers
struct CookChartView: View {
    @Environment(AppSettings.self) private var settings
    let cook: Cook
    let estimates: [ChannelKey: Estimate]
    let unit: TemperatureUnit
    let now: Date
    let isLive: Bool
    var staleChannels: Set<ChannelKey> = []
    /// Cook timeline → real time, for the self-updating "x minutes ago".
    var wallClock: @Sendable (Date) -> Date = { $0 }

    @State private var hidden: Set<ChannelKey> = []
    @State private var visibleLength: TimeInterval = 30 * 60
    @State private var fitAll = false
    @State private var followLive = true
    @State private var scrollPosition: Date = .distantPast
    @State private var programmaticScroll = false
    @State private var selectedTime: Date?
    @State private var pinchBase: TimeInterval?

    private var start: Date { cook.startedAt }
    private var end: Date { max(cook.endedAt ?? now, start.addingTimeInterval(60)) }
    private var duration: TimeInterval { end.timeIntervalSince(start) }
    private var effectiveLength: TimeInterval {
        fitAll ? duration : ChartSeriesBuilder.clampVisibleLength(visibleLength, cookDuration: duration)
    }
    /// Breathing room after the newest reading so it isn't drawn on the plot edge.
    private var trailingPad: TimeInterval { effectiveLength * 0.03 }
    private var domainEnd: Date { end.addingTimeInterval(trailingPad) }
    private var liveEdge: Date { max(start, domainEnd.addingTimeInterval(-effectiveLength)) }

    var body: some View {
        let margin = effectiveLength
        let window = scrollPosition.addingTimeInterval(-margin)...scrollPosition.addingTimeInterval(effectiveLength + margin)
        // Downsample over the visible window (with margin) so panning stays smooth on long cooks.
        let series = ChartSeriesBuilder.series(for: cook, unit: unit, hidden: hidden, window: window, maxPointsPerSeries: 400)
        VStack(alignment: .leading, spacing: 8) {
            ChartReadout(cook: cook, unit: unit, selectedTime: selectedTime, isLive: isLive,
                         elapsed: settings.chartShowsElapsedTime, staleChannels: staleChannels,
                         wallClock: wallClock, hidden: $hidden)
            chart(series)
        }
        .onAppear {
            fitAll = !isLive
            jumpToLive()
        }
        .onChange(of: now) {
            if followLive { jumpToLive() }
        }
        .onChange(of: scrollPosition) { _, newValue in
            if programmaticScroll {
                programmaticScroll = false
                return
            }
            // The user scrolled: keep following only if they're (back) at the live edge.
            followLive = newValue >= liveEdge.addingTimeInterval(-effectiveLength * 0.02)
        }
    }

    private func jumpToLive() {
        followLive = true
        let target = liveEdge
        guard abs(target.timeIntervalSince(scrollPosition)) > 0.5 else { return }
        programmaticScroll = true
        scrollPosition = target
    }

    private func chart(_ series: [ChartSeries]) -> some View {
        let ticks = ChartSeriesBuilder.axisTicks(from: start, to: domainEnd, visibleLength: effectiveLength,
                                                 alignedToStart: settings.chartShowsElapsedTime)
        return Chart {
            ForEach(series) { s in
                let color = ProbePalette.color(s.colorIndex, role: s.role)
                ForEach(s.points) { p in
                    LineMark(x: .value("Time", p.time), y: .value("Temperature", p.value), series: .value("Probe", s.key.description))
                        .foregroundStyle(color)
                        .lineStyle(s.role == .ambient ? StrokeStyle(lineWidth: 2, dash: [6, 4]) : StrokeStyle(lineWidth: 2.5))
                        .interpolationMethod(.monotone)
                }
                if s.role == .internal, let target = s.target {
                    // Labeled in the readout ("→ 203°"); an in-plot label would clip when scrolled.
                    RuleMark(y: .value("Target", target))
                        .foregroundStyle(color.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    // ETA projection: dashed segment from the latest reading to (ETA, target).
                    // TODO(M4): draw the fitted Newton curve with an uncertainty band.
                    if isLive, let last = s.points.last, let eta = estimates[s.key]?.eta, estimates[s.key]?.state == .estimating {
                        ForEach([ChartPoint(time: last.time, value: last.value), ChartPoint(time: eta, value: target)]) { p in
                            LineMark(x: .value("Time", p.time), y: .value("Temperature", p.value), series: .value("Projection", "proj-\(s.key)"))
                                .foregroundStyle(color.opacity(0.45))
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
                    .foregroundStyle(.primary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartYScale(domain: ChartSeriesBuilder.yDomain(series))
        .chartXScale(domain: start...max(domainEnd, start.addingTimeInterval(effectiveLength)))
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: effectiveLength)
        .chartScrollPosition(x: $scrollPosition)
        .chartXSelection(value: $selectedTime)
        .chartXAxis {
            AxisMarks(values: ticks) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisTick()
                // Labels are centered on their tick, so one hugging the visible edge would be cut in half.
                if let date = value.as(Date.self), isLabelSafelyVisible(date) {
                    AxisValueLabel {
                        Text(axisLabel(date)).font(.caption2.monospacedDigit())
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text("\(Int(v))°").font(.caption2.monospacedDigit()) }
                }
            }
        }
        .chartLegend(.hidden)
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    let base = pinchBase ?? effectiveLength
                    pinchBase = base
                    fitAll = false
                    visibleLength = ChartSeriesBuilder.clampVisibleLength(base / value.magnification, cookDuration: duration)
                    if followLive { jumpToLive() }
                }
                .onEnded { _ in pinchBase = nil }
        )
        .onTapGesture(count: 2) {
            fitAll.toggle()
            if !fitAll { visibleLength = 30 * 60 }
            jumpToLive()
        }
        .overlay(alignment: .topTrailing) {
            if isLive, !followLive {
                Button("Live", systemImage: "forward.end.fill") { jumpToLive() }
                    .font(.caption.bold())
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(AccessibilityID.Live.jumpToLive)
            }
        }
    }

    private func isLabelSafelyVisible(_ date: Date) -> Bool {
        let visibleStart = max(scrollPosition, start)
        let inset = effectiveLength * 0.09
        return date >= visibleStart.addingTimeInterval(inset)
            && date <= visibleStart.addingTimeInterval(effectiveLength - inset)
    }

    private func axisLabel(_ date: Date) -> String {
        if settings.chartShowsElapsedTime {
            return Formatting.elapsedAxis(date.timeIntervalSince(start))
        }
        return date.formatted(.dateTime.hour(.defaultDigits(amPM: .narrow)).minute())
    }
}

/// Values for every series at "now" (or the scrubbed time), above the plot so it can never be
/// clipped. Each item is also the series' legend entry and visibility toggle.
private struct ChartReadout: View {
    @Environment(AppSettings.self) private var settings
    let cook: Cook
    let unit: TemperatureUnit
    let selectedTime: Date?
    let isLive: Bool
    let elapsed: Bool
    let staleChannels: Set<ChannelKey>
    let wallClock: @Sendable (Date) -> Date
    @Binding var hidden: Set<ChannelKey>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                timeHeader
                Spacer()
                @Bindable var settings = settings
                Picker("Axis", selection: $settings.chartShowsElapsedTime) {
                    Text("Clock").tag(false)
                    Text("Elapsed").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .controlSize(.mini)
                .accessibilityIdentifier(AccessibilityID.Live.chartAxisMode)
            }
            FlowLayout(spacing: 6) {
                ForEach(cook.probes) { probe in
                    item(probe)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Live.chartReadout)
    }

    /// Scrubbing: the selected moment. Otherwise how fresh the newest reading is (live), or when the cook ended.
    @ViewBuilder
    private var timeHeader: some View {
        if let selectedTime {
            Text(timeLabel(selectedTime))
                .font(.caption.monospacedDigit().weight(.semibold))
        } else if isLive {
            FreshnessLabel(readingTime: latestTime, readingWallClock: latestTime.map(wallClock),
                           isStale: !cook.probes.isEmpty && cook.probes.allSatisfy { staleChannels.contains($0.key) })
        } else if let latestTime {
            Text("Last reading " + timeLabel(latestTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func timeLabel(_ time: Date) -> String {
        let clock = time.formatted(date: .omitted, time: .shortened)
        let since = "+" + Formatting.duration(time.timeIntervalSince(cook.startedAt))
        return elapsed ? "\(since) · \(clock)" : "\(clock) · \(since)"
    }

    private var latestTime: Date? {
        cook.series.values.compactMap(\.last?.time).max()
    }

    private func item(_ probe: CookProbe) -> some View {
        let isHidden = hidden.contains(probe.key)
        let samples = cook.series[probe.key] ?? []
        let sample = selectedTime.map { ChartSeriesBuilder.sample(at: $0, in: samples) } ?? samples.last
        let valueText = sample.map { $0.temperature.formatted(unit, fractionDigits: 1) } ?? "--"
        let isStale = selectedTime == nil && staleChannels.contains(probe.key)
        return Button {
            if isHidden { hidden.remove(probe.key) } else { hidden.insert(probe.key) }
        } label: {
            HStack(spacing: 5) {
                ProbeSwatch(colorIndex: probe.colorIndex, role: probe.role)
                Text(probe.label).foregroundStyle(.secondary)
                Text(valueText).monospacedDigit().foregroundStyle(isStale ? .secondary : .primary)
                    .accessibilityIdentifier(AccessibilityID.Live.readoutValue(probe.key.description))
                if probe.role == .internal, let target = probe.target {
                    Text("→ \(target.formatted(unit))").foregroundStyle(.secondary)
                }
                if isStale, let sample {
                    // This channel stopped reporting; say how old its value is.
                    Text("@ \(sample.time.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2.weight(.semibold))
                }
            }
            .font(.caption)
            .opacity(isHidden ? 0.35 : 1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.background.secondary, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.Live.legendChip(probe.key.description))
        .accessibilityValue(isHidden ? "hidden" : "shown")
    }
}

/// Left-to-right wrapping layout for the readout chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
