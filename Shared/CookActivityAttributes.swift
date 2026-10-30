#if canImport(ActivityKit)
import ActivityKit
import Foundation

/// Live Activity payload. Compiled into both the app and the widget extension.
/// Keep ContentState small (< 4 KB) — it's also the future ActivityKit push payload (SPEC §4.2).
struct CookActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var probeLabel: String
        var currentCelsius: Double?
        var targetCelsius: Double?
        /// Temperature when the cook started — progress bar origin.
        var startCelsius: Double?
        var eta: Date?
        /// Short status, e.g. "Stall", "Calculating…", "Done".
        var status: String?
        /// "F" or "C".
        var unit: String
        var isEnded: Bool = false
    }

    var cookID: UUID
    var title: String
    var startedAt: Date
}
#endif
