import ActivityKit
import CookCore
import SwiftUI
import WidgetKit

/// Lock screen + Dynamic Island (SPEC §7.5). Elapsed time and ETA use self-updating timer text,
/// so they keep ticking while the app is suspended.
struct CookLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CookActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state)
                .padding()
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.orange)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading) {
                        Text(state.probeLabel).font(.caption).foregroundStyle(.secondary)
                        TempText(celsius: state.currentCelsius, unit: state.unit).font(.title2.bold())
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing) {
                        Text("Target").font(.caption).foregroundStyle(.secondary)
                        TempText(celsius: state.targetCelsius, unit: state.unit).font(.title3)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Label { Text(context.attributes.startedAt, style: .timer) } icon: { Image(systemName: "clock") }
                        Spacer()
                        ETAText(state: state)
                    }
                    .font(.subheadline.monospacedDigit())
                }
            } compactLeading: {
                TempText(celsius: state.currentCelsius, unit: state.unit, symbol: false).foregroundStyle(.orange)
            } compactTrailing: {
                ETAText(state: state, compact: true).frame(maxWidth: 56)
            } minimal: {
                TempText(celsius: state.currentCelsius, unit: state.unit, symbol: false).foregroundStyle(.orange)
            }
        }
    }
}

private struct LockScreenView: View {
    let attributes: CookActivityAttributes
    let state: CookActivityAttributes.ContentState

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
            if let progress {
                ProgressView(value: progress).tint(.orange)
            }
        }
    }

    private var progress: Double? {
        guard let start = state.startCelsius, let current = state.currentCelsius, let target = state.targetCelsius, target > start else { return nil }
        return min(max((current - start) / (target - start), 0), 1)
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
