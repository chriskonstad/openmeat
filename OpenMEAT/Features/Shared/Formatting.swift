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

    /// "+1.2°/min"
    static func rate(_ celsiusPerMinute: Double?, unit: TemperatureUnit) -> String? {
        guard let celsiusPerMinute else { return nil }
        let value = Temperature.deltaCelsius(celsiusPerMinute, in: unit)
        return value.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always())) + "°/min"
    }
}

enum ProbePalette {
    static let colors: [Color] = [.orange, .red, .purple, .blue, .green, .pink, .teal, .brown]
    static func color(_ index: Int) -> Color { colors[index % colors.count] }
}
