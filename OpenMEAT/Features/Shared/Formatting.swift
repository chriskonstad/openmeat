import CookCore
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

    static func color(_ index: Int, role: ProbeRole = .internal) -> Color {
        let (light, dark) = slots[((index % slots.count) + slots.count) % slots.count]
        let base = Color(UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
        return role == .ambient ? base.opacity(0.55) : base
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
