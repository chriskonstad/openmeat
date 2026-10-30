import Foundation

/// Accessibility identifiers shared by the app and UI tests, so tests never depend on copy.
enum AccessibilityID {
    enum Login {
        static let email = "login.email"
        static let password = "login.password"
        static let signIn = "login.signIn"
        static let demo = "login.demo"
        static let error = "login.error"
    }

    enum StartCook {
        static let title = "startCook.title"
        static let start = "startCook.start"
        static let refresh = "startCook.refresh"
        static func probeToggle(_ key: String) -> String { "startCook.probe.\(key)" }
    }

    enum Live {
        static let screen = "live.screen"
        static let elapsed = "live.elapsed"
        static let endCook = "live.endCook"
        static let confirmEnd = "live.confirmEnd"
        static let chart = "live.chart"
        static let jumpToLive = "live.jumpToLive"
        static func probeCard(_ key: String) -> String { "live.probe.\(key)" }
        static func probeTemp(_ key: String) -> String { "live.probe.\(key).temp" }
        static func targetButton(_ key: String) -> String { "live.probe.\(key).target" }
        static func eta(_ key: String) -> String { "live.probe.\(key).eta" }
        static func legendChip(_ key: String) -> String { "live.legend.\(key)" }
    }

    enum Target {
        static let picker = "target.picker"
        static let value = "target.value"
        static let increment = "target.increment"
        static let decrement = "target.decrement"
        static let save = "target.save"
        static let clear = "target.clear"
        static func preset(_ id: String) -> String { "target.preset.\(id)" }
    }

    enum Notes {
        static let addButton = "notes.add"
        static let field = "notes.field"
        static let save = "notes.save"
        static let list = "notes.list"
        static func quick(_ text: String) -> String { "notes.quick.\(text)" }
    }

    enum Tabs {
        static let live = "tab.live"
        static let history = "tab.history"
        static let settings = "tab.settings"
    }

    enum History {
        static let list = "history.list"
        static let empty = "history.empty"
        static func row(_ id: String) -> String { "history.row.\(id)" }
        static let detailChart = "history.detail.chart"
        static let export = "history.detail.export"
    }

    enum Settings {
        static let unit = "settings.unit"
        static let leadTime = "settings.leadTime"
        static let leadTimeValue = "settings.leadTime.value"
        static let liveActivities = "settings.liveActivities"
        static let signOut = "settings.signOut"
    }
}
