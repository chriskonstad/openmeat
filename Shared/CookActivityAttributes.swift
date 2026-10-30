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
        /// Wall-clock time the target was first reached; the activity then counts up from it.
        var targetReachedAt: Date?
        /// Short status, e.g. "Stall", "Calculating…", "Done".
        var status: String?
        /// "F" or "C".
        var unit: String
        /// Wall-clock time of the newest reading shown. Always displayed ("Updated 3:42 PM · 4 minutes ago").
        var updatedAt: Date
        /// The probes themselves stopped reporting (gateway offline etc.), even though the app is updating.
        var isDataStale: Bool = false
        var isEnded: Bool = false
    }

    var cookID: UUID
    var title: String
    var startedAt: Date
}
#endif
