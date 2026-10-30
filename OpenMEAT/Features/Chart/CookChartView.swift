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
/// - target rules, ETA projection
/// - labeled note markers: tap one (or scrub near it) to read the whole note above the plot
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
    @State private var focusedNoteID: UUID?
    @State private var plotWidth: CGFloat = 300
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
                         wallClock: wallClock, note: shownNote, isNotePinned: focusedNoteID != nil,
                         onDismissNote: { focusedNoteID = nil }, hidden: $hidden)
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

    /// Approximate on-screen x of each note's marker (plot starts at the leading edge).
    private var notePositions: [(CookNote, CGFloat)] {
        let visibleStart = max(scrollPosition, start)
        return cook.notes.map { note in
            (note, CGFloat(note.time.timeIntervalSince(visibleStart) / effectiveLength) * plotWidth)
        }
    }

    /// Flag rows for notes in view.
    private var noteRows: [UUID: Int] {
        Dictionary(uniqueKeysWithValues: NoteFlagLayout.place(notePositions, plotWidth: plotWidth).map { ($0.note.id, $0.row) })
    }

    /// The note shown in the readout: the one the user tapped, else one close to the scrubbed time.
    private var shownNote: CookNote? {
        if let focusedNoteID, let note = cook.notes.first(where: { $0.id == focusedNoteID }) { return note }
        guard let selectedTime else { return nil }
        return ChartSeriesBuilder.note(near: selectedTime, in: cook.notes, tolerance: effectiveLength * 0.03)
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
                let isFocused = note.id == shownNote?.id
                RuleMark(x: .value("Note", note.time))
                    .foregroundStyle(.primary.opacity(isFocused ? 0.7 : 0.3))
                    .lineStyle(StrokeStyle(lineWidth: isFocused ? 1.5 : 1, dash: [3, 3]))
                    .annotation(position: .overlay, alignment: .top, spacing: 0,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        // Staggered onto a second row when it would overlap a neighbor. Annotations
                        // aren't interactive; taps are hit-tested by the chart's tap gesture.
                        NoteFlag(text: note.text, isFocused: isFocused)
                            .offset(y: CGFloat(noteRows[note.id] ?? 0) * 22)
                    }
                    .accessibilityLabel("Note")
                    .accessibilityValue(note.text)
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
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            plotWidth = max(width - 44, 100) // minus the trailing Y-axis labels
        }
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
        // Tap a note marker to read it in the readout; tap elsewhere to dismiss. Simultaneous, because
        // the chart's scroll/selection gestures otherwise swallow single taps.
        .simultaneousGesture(SpatialTapGesture(count: 1, coordinateSpace: .local).onEnded { value in
            let hit = NoteFlagLayout.hit(x: value.location.x, positions: notePositions, tolerance: 26)
            focusedNoteID = hit.map { $0.id == focusedNoteID ? nil : $0.id } ?? nil
        })
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
        let visibleEnd = min(visibleStart.addingTimeInterval(effectiveLength), domainEnd)
        return date >= visibleStart.addingTimeInterval(inset) && date <= visibleEnd.addingTimeInterval(-inset)
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
    let note: CookNote?
    let isNotePinned: Bool
    let onDismissNote: () -> Void
    @Binding var hidden: Set<ChannelKey>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let note {
                noteRow(note)
            }
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

    private func noteRow(_ note: CookNote) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "note.text")
            Text(timeLabel(note.time)).monospacedDigit().foregroundStyle(.secondary)
            Text(note.text).fontWeight(.semibold).frame(maxWidth: .infinity, alignment: .leading)
            if isNotePinned {
                Button("Close note", systemImage: "xmark.circle.fill", action: onDismissNote)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.Live.noteDetail)
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
                // Fixed width (sized for the widest plausible value) so chips don't re-wrap as numbers grow.
                ZStack(alignment: .leading) {
                    Text("888.8°F").hidden()
                    Text(valueText).foregroundStyle(isStale ? .secondary : .primary)
                }
                .monospacedDigit()
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

/// Label at the top of a note's marker line, so markers explain themselves.
private struct NoteFlag: View {
    let text: String
    let isFocused: Bool

    static func shortText(_ text: String) -> String {
        text.count > 14 ? String(text.prefix(13)).trimmingCharacters(in: .whitespaces) + "…" : text
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "note.text")
            Text(Self.shortText(text))
        }
        .font(.caption2.weight(isFocused ? .semibold : .regular))
        .foregroundStyle(isFocused ? .primary : .secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(.background, in: Capsule())
        .overlay(Capsule().strokeBorder(.secondary.opacity(isFocused ? 0.8 : 0.35)))
        .fixedSize()
    }
}

/// Places note flags along the top of the plot: centered on their marker, kept inside the plot,
/// and moved to a second row when they'd overlap a neighbor. Pure — unit tested.
enum NoteFlagLayout {
    struct Flag {
        var note: CookNote
        var x: CGFloat
        var row: Int
    }

    static func estimatedWidth(_ text: String) -> CGFloat {
        26 + CGFloat(NoteFlag.shortText(text).count) * 6.3
    }

    /// The note whose marker is nearest to a tap at `x`, if within `tolerance` points.
    static func hit(x: CGFloat, positions: [(CookNote, CGFloat)], tolerance: CGFloat) -> CookNote? {
        positions.map { ($0.0, abs($0.1 - x)) }
            .filter { $0.1 <= tolerance }
            .min { $0.1 < $1.1 }?.0
    }

    static func place(_ positioned: [(CookNote, CGFloat)], plotWidth: CGFloat, rows: Int = 2) -> [Flag] {
        var rowEnds = Array(repeating: -CGFloat.infinity, count: rows)
        var flags: [Flag] = []
        for (note, markerX) in positioned.sorted(by: { $0.1 < $1.1 }) where markerX >= 0 && markerX <= plotWidth {
            let width = estimatedWidth(note.text)
            let x = min(max(markerX, width / 2), max(plotWidth - width / 2, width / 2))
            let row = rowEnds.firstIndex { $0 + 4 <= x - width / 2 }
                ?? rowEnds.indices.min { rowEnds[$0] < rowEnds[$1] }!
            rowEnds[row] = x + width / 2
            flags.append(Flag(note: note, x: x, row: row))
        }
        return flags
    }
}
