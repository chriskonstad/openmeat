import CookCore
import Foundation
import Observation

/// User preferences, persisted in UserDefaults.
@MainActor @Observable
final class AppSettings {
    private let defaults: UserDefaults

    var unit: TemperatureUnit {
        didSet { defaults.set(unit.rawValue, forKey: Keys.unit) }
    }
    /// "Almost done" lead time, minutes. Default 5.
    var almostDoneLeadMinutes: Int {
        didSet { defaults.set(almostDoneLeadMinutes, forKey: Keys.lead) }
    }
    var pollIntervalSeconds: Double {
        didSet { defaults.set(pollIntervalSeconds, forKey: Keys.poll) }
    }
    var liveActivitiesEnabled: Bool {
        didSet { defaults.set(liveActivitiesEnabled, forKey: Keys.liveActivities) }
    }
    var quickNotes: [String] {
        didSet { defaults.set(quickNotes, forKey: Keys.quickNotes) }
    }

    var almostDoneLeadTime: TimeInterval { TimeInterval(almostDoneLeadMinutes * 60) }

    static let leadMinutesRange = 1...60

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        unit = TemperatureUnit(code: defaults.string(forKey: Keys.unit)) ?? .fahrenheit
        almostDoneLeadMinutes = defaults.object(forKey: Keys.lead) as? Int ?? 5
        pollIntervalSeconds = defaults.object(forKey: Keys.poll) as? Double ?? 15
        liveActivitiesEnabled = defaults.object(forKey: Keys.liveActivities) as? Bool ?? true
        quickNotes = defaults.stringArray(forKey: Keys.quickNotes) ?? QuickNotes.defaults
    }

    func reset() {
        for key in [Keys.unit, Keys.lead, Keys.poll, Keys.liveActivities, Keys.quickNotes] {
            defaults.removeObject(forKey: key)
        }
    }

    private enum Keys {
        static let unit = "settings.unit"
        static let lead = "settings.almostDoneLeadMinutes"
        static let poll = "settings.pollIntervalSeconds"
        static let liveActivities = "settings.liveActivitiesEnabled"
        static let quickNotes = "settings.quickNotes"
    }
}
