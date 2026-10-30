import CookCore
import CookSession
import SwiftUI

enum Formatting {
    /// "1h 12m", "8m", "45s"
    static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        let h = seconds / 3600, m = (seconds % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(seconds)s"
    }

    /// Text for an estimate on a probe card.
    static func etaText(_ estimate: Estimate?, hasTarget: Bool, now: Date) -> String {
        guard hasTarget else { return "No target" }
        guard let estimate else { return "Calculating…" }
        switch estimate.state {
        case .warmingUp: return "Calculating…"
        case .stalled: return "Stall"
        case .reached: return "Done"
        case .unavailable: return "—"
        case .estimating:
            guard let eta = estimate.eta else { return "—" }
            return "~\(duration(eta.timeIntervalSince(now))) · \(eta.formatted(date: .omitted, time: .shortened))"
        }
    }

    /// Stopwatch style: "7:05", "1:12:05".
    static func clock(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Compact elapsed label for chart axes: "45m", "2h", "2h30".
    static func elapsedAxis(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int((interval / 60).rounded()))
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : String(format: "%dh%02d", h, m)
    }

    /// "+1.2°/min"
    static func rate(_ celsiusPerMinute: Double?, unit: TemperatureUnit) -> String? {
        guard let celsiusPerMinute else { return nil }
        let value = Temperature.deltaCelsius(celsiusPerMinute, in: unit)
        return value.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always())) + "°/min"
    }
}

/// Categorical colors for probes: one hue per meat probe, in a fixed order validated for
/// color-vision deficiency (adjacent pairs) in light and dark mode. Ambient sensors use a lighter
/// tint of the hue of the meat probe they serve, and are drawn dashed — identity never relies on
/// color alone (dash, ring swatch and labels too).
enum ProbePalette {
    /// (light, dark) pairs — blue, orange, aqua, yellow, magenta, green, violet, red.
    private static let slots: [(UInt32, UInt32)] = [
        (0x2a78d6, 0x3987e5), (0xeb6834, 0xd95926), (0x1baf7a, 0x199e70), (0xeda100, 0xc98500),
        (0xe87ba4, 0xd55181), (0x008300, 0x008300), (0x6250d6, 0x9085e9), (0xe34948, 0xe66767),
    ]

    /// Index `CookProbe.neutralColor` (an ambient shared by several probes) is neutral gray.
    static func color(_ index: Int, role: ProbeRole = .internal) -> Color {
        guard index >= 0 else { return Color(UIColor.systemGray) }
        let (light, dark) = slots[index % slots.count]
        let base = Color(UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
        switch role {
        case .ambient: return base.opacity(0.55)
        case .sensor: return base.opacity(0.4)
        case .internal, .unknown: return base
        }
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

/// "Updated 3:42 PM · 2 minutes ago" — the relative part updates itself. Becomes a warning when
/// the data is stale (probes not reporting / app was suspended) or the last poll failed.
struct FreshnessLabel: View {
    /// Newest reading, in the cook's timeline (shown as a clock time).
    let readingTime: Date?
    /// The same moment on the real clock (differs only in accelerated demo mode).
    let readingWallClock: Date?
    var isStale = false
    var error: String?

    var body: some View {
        let warning = isStale || error != nil
        HStack(spacing: 4) {
            Image(systemName: warning ? "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90" : "arrow.trianglehead.2.clockwise")
            if let readingTime, let readingWallClock {
                Text("Updated \(readingTime.formatted(date: .omitted, time: .shortened)) ·")
                Text(.currentDate, format: .reference(to: readingWallClock, allowedFields: [.day, .hour, .minute], maxFieldCount: 1))
            } else {
                Text("Waiting for first reading…")
            }
            if let error {
                Text("· \(error)").lineLimit(1)
            } else if isStale {
                Text("· no new readings")
            }
        }
        .font(.caption.weight(warning ? .semibold : .regular))
        .foregroundStyle(warning ? .primary : .secondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.Live.lastUpdated)
    }
}

/// Battery icon + percent for a device. Status color (orange/red) only when it needs attention,
/// always with the percent or a word, never color alone. Shows nothing for devices without a battery
/// except the gateway, which says "No battery".
struct BatteryBadge: View {
    let health: DeviceHealth
    var compact = false

    var body: some View {
        Group {
            switch health.battery {
            case .none:
                if health.isGateway, !compact {
                    Text("No battery reported").foregroundStyle(.secondary)
                }
            case .ok(let percent):
                badge(symbol: Self.symbol(percent), percent: percent, word: "OK", color: .secondary)
            case .low(let percent):
                // < 50 %: yellow-orange (the icon's amber).
                badge(symbol: Self.symbol(percent), percent: percent, word: "Low", color: Brand.amber)
            case .critical(let percent):
                // < 20 %: red.
                badge(symbol: "battery.0percent", percent: percent, word: "Critical", color: .red)
            }
        }
        .font(compact ? .caption : .subheadline)
        .accessibilityIdentifier(AccessibilityID.deviceBattery(health.serial))
    }

    private func badge(symbol: String, percent: Int?, word: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text(percent.map { "\($0)%" } ?? word).monospacedDigit()
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery \(percent.map { "\($0) percent" } ?? word)")
    }

    static func symbol(_ percent: Int?) -> String {
        guard let percent else { return "battery.75percent" }
        switch percent {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}
