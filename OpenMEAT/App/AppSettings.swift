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
    /// Keep the display awake while a cook is open in the foreground (live data, no background limits).
    var keepScreenOn: Bool {
        didSet { defaults.set(keepScreenOn, forKey: Keys.keepScreenOn) }
    }
    /// Chart X axis: clock time or time since the cook started.
    var chartShowsElapsedTime: Bool {
        didSet { defaults.set(chartShowsElapsedTime, forKey: Keys.chartElapsed) }
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
        keepScreenOn = defaults.object(forKey: Keys.keepScreenOn) as? Bool ?? true
        chartShowsElapsedTime = defaults.bool(forKey: Keys.chartElapsed)
    }

    func reset() {
        for key in [Keys.unit, Keys.lead, Keys.poll, Keys.liveActivities, Keys.quickNotes, Keys.keepScreenOn, Keys.chartElapsed] {
            defaults.removeObject(forKey: key)
        }
        let fresh = AppSettings(defaults: defaults)
        unit = fresh.unit
        almostDoneLeadMinutes = fresh.almostDoneLeadMinutes
        pollIntervalSeconds = fresh.pollIntervalSeconds
        liveActivitiesEnabled = fresh.liveActivitiesEnabled
        quickNotes = fresh.quickNotes
        keepScreenOn = fresh.keepScreenOn
        chartShowsElapsedTime = fresh.chartShowsElapsedTime
        // The didSets above re-wrote defaults; clear again so "unset" means "use the default".
        for key in [Keys.unit, Keys.lead, Keys.poll, Keys.liveActivities, Keys.quickNotes, Keys.keepScreenOn, Keys.chartElapsed] {
            defaults.removeObject(forKey: key)
        }
    }

    private enum Keys {
        static let unit = "settings.unit"
        static let lead = "settings.almostDoneLeadMinutes"
        static let poll = "settings.pollIntervalSeconds"
        static let liveActivities = "settings.liveActivitiesEnabled"
        static let quickNotes = "settings.quickNotes"
        static let keepScreenOn = "settings.keepScreenOn"
        static let chartElapsed = "settings.chartShowsElapsedTime"
    }
}
