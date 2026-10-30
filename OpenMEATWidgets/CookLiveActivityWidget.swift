import ActivityKit
import CookCore
import SwiftUI
import WidgetKit

/// Lock screen + Dynamic Island (SPEC §7.5). Elapsed time and ETA use self-updating timer text,
/// so they keep ticking while the app is suspended.
struct CookLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CookActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state, isStale: context.isStale)
                .padding()
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                // The expanded island's corners are heavily rounded; inset the corner regions.
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading) {
                        Text(state.probeLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        TempText(celsius: state.currentCelsius, unit: state.unit).font(.title2.bold())
                    }
                    .padding(.leading, 8)
                    .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing) {
                        Text("Target").font(.caption).foregroundStyle(.secondary)
                        TempText(celsius: state.targetCelsius, unit: state.unit).font(.title3)
                    }
                    .padding(.trailing, 8)
                    .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        HStack {
                            Label { Text(context.attributes.startedAt, style: .timer) } icon: { Image(systemName: "clock") }
                            Spacer()
                            ETAText(state: state)
                        }
                        .font(.subheadline.monospacedDigit())
                        CookProgress(startedAt: context.attributes.startedAt, state: state)
                        FreshnessText(state: state, activityIsStale: context.isStale)
                    }
                }
            } compactLeading: {
                // Old data is marked even in the smallest presentations.
                CompactTemp(state: state, activityIsStale: context.isStale)
            } compactTrailing: {
                ETAText(state: state, compact: true).frame(maxWidth: 56)
            } minimal: {
                CompactTemp(state: state, activityIsStale: context.isStale)
            }
        }
    }
}

private struct LockScreenView: View {
    let attributes: CookActivityAttributes
    let state: CookActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(attributes.title).font(.headline)
                Spacer()
                Text("Started \(attributes.startedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                TempText(celsius: state.currentCelsius, unit: state.unit).font(.system(size: 34, weight: .bold, design: .rounded))
                if state.targetCelsius != nil {
                    Text("→").foregroundStyle(.secondary)
                    TempText(celsius: state.targetCelsius, unit: state.unit).font(.title3)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text(attributes.startedAt, style: .timer).font(.subheadline.monospacedDigit())
                    ETAText(state: state).font(.subheadline.bold())
                }
            }
            CookProgress(startedAt: attributes.startedAt, state: state)
            FreshnessText(state: state, activityIsStale: isStale)
        }
    }
}

/// While an ETA is known, a time-based bar from cook start to ETA that advances on its own between
/// updates (ProgressView(timerInterval:) is rendered by the system). Otherwise temperature progress.
private struct CookProgress: View {
    let startedAt: Date
    let state: CookActivityAttributes.ContentState

    var body: some View {
        if let eta = state.eta, eta > startedAt, state.status == nil {
            ProgressView(timerInterval: startedAt...eta, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                .tint(.primary)
        } else if let progress {
            ProgressView(value: progress).tint(.primary)
        }
    }

    private var progress: Double? {
        guard let start = state.startCelsius, let current = state.currentCelsius, let target = state.targetCelsius, target > start else { return nil }
        return min(max((current - start) / (target - start), 0), 1)
    }
}

/// Always visible: when the newest reading was taken, and a self-updating "x minutes ago".
/// Turns into a warning when the app hasn't updated the activity in a while (`activityIsStale`,
/// i.e. iOS suspended it) or the probes stopped reporting (`state.isDataStale`).
private struct FreshnessText: View {
    let state: CookActivityAttributes.ContentState
    let activityIsStale: Bool

    var body: some View {
        let warning = activityIsStale || state.isDataStale
        HStack(spacing: 4) {
            Image(systemName: warning ? "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90" : "arrow.trianglehead.2.clockwise")
            Text("Updated \(state.updatedAt.formatted(date: .omitted, time: .shortened)) ·")
            Text(.currentDate, format: .reference(to: state.updatedAt, allowedFields: [.day, .hour, .minute], maxFieldCount: 1))
            if activityIsStale {
                Text("· open app to refresh")
            } else if state.isDataStale {
                Text("· probe not reporting")
            }
        }
        .font(.caption2.weight(warning ? .semibold : .regular))
        .foregroundStyle(warning ? .primary : .secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CompactTemp: View {
    let state: CookActivityAttributes.ContentState
    let activityIsStale: Bool

    var body: some View {
        let warning = activityIsStale || state.isDataStale
        HStack(spacing: 2) {
            if warning { Image(systemName: "clock.badge.exclamationmark").font(.caption2) }
            TempText(celsius: state.currentCelsius, unit: state.unit, symbol: false)
        }
        .foregroundStyle(warning ? .secondary : .primary)
    }
}

private struct TempText: View {
    let celsius: Double?
    let unit: String
    var symbol = true

    var body: some View {
        if let celsius, let u = TemperatureUnit(code: unit) {
            Text(Temperature(celsius: celsius).formatted(u, symbol: symbol)).monospacedDigit()
        } else {
            Text("--")
        }
    }
}

private struct ETAText: View {
    let state: CookActivityAttributes.ContentState
    var compact = false

    var body: some View {
        if let status = state.status {
            Text(status)
        } else if let eta = state.eta, eta > Date() {
            Text(timerInterval: Date()...eta, countsDown: true, showsHours: true)
                .multilineTextAlignment(.trailing)
        } else if state.targetCelsius == nil {
            Text(compact ? "" : "No target")
        } else {
            Text("Soon")
        }
    }
}
