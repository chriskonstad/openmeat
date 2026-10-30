import ActivityKit
import CookCore
import SwiftUI
import WidgetKit

/// Lock screen + Dynamic Island (SPEC §7.5), in the app icon's palette (`Brand`). Elapsed time,
/// ETA and progress use self-updating views, so they keep moving while the app is suspended.
struct CookLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CookActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state, isStale: context.isStale)
                .padding()
                .activityBackgroundTint(Brand.charcoal)
                .activitySystemActionForegroundColor(Brand.ember)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                // The expanded island's corners are heavily rounded; inset the corner regions.
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading) {
                        Text(state.probeLabel).font(.caption).foregroundStyle(Brand.creamSecondary).lineLimit(1)
                        TempText(celsius: state.currentCelsius, unit: state.unit).font(.title2.bold())
                            .foregroundStyle(Brand.cream)
                    }
                    .padding(.leading, 8)
                    .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing) {
                        Text("Target").font(.caption).foregroundStyle(Brand.creamSecondary)
                        TempText(celsius: state.targetCelsius, unit: state.unit).font(.title3.weight(.semibold))
                            .foregroundStyle(Brand.ember)
                    }
                    .padding(.trailing, 8)
                    .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        HStack {
                            Label { Text(context.attributes.startedAt, style: .timer) } icon: { Image(systemName: "clock") }
                                .foregroundStyle(Brand.creamSecondary)
                            Spacer()
                            ETAText(state: state).foregroundStyle(Brand.amber).bold()
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
                ETAText(state: state, compact: true)
                    .foregroundStyle(Brand.amber)
                    .frame(maxWidth: 56)
            } minimal: {
                CompactTemp(state: state, activityIsStale: context.isStale)
            }
            .keylineTint(Brand.ember)
        }
    }
}

private struct LockScreenView: View {
    let attributes: CookActivityAttributes
    let state: CookActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                BrandMark().frame(width: 22, height: 18)
                Text(attributes.title).font(.headline).foregroundStyle(Brand.cream)
                Spacer()
                Text("Started \(attributes.startedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(Brand.creamSecondary)
            }
            HStack(alignment: .firstTextBaseline) {
                TempText(celsius: state.currentCelsius, unit: state.unit)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(Brand.cream)
                if state.targetCelsius != nil {
                    Image(systemName: "arrow.right").font(.caption.bold()).foregroundStyle(Brand.creamSecondary)
                    TempText(celsius: state.targetCelsius, unit: state.unit)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Brand.ember)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text(attributes.startedAt, style: .timer).font(.subheadline.monospacedDigit())
                        .foregroundStyle(Brand.creamSecondary)
                    ETAText(state: state).font(.subheadline.bold()).foregroundStyle(Brand.amber)
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
        Group {
            if let eta = state.eta, eta > startedAt, state.status == nil {
                ProgressView(timerInterval: startedAt...eta, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
            } else if let progress {
                ProgressView(value: progress)
            }
        }
        .tint(Brand.ember)
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
        .foregroundStyle(warning ? Brand.amber : Brand.creamSecondary)
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
        .foregroundStyle(warning ? Brand.creamSecondary : Brand.ember)
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
