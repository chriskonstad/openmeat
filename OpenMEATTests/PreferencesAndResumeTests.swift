import CookCore
import CookSession
import Foundation
import Testing
@testable import OpenMEAT

private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "openmeat-tests-\(UUID().uuidString)")!
}

@MainActor
@Suite("Channel preferences")
struct ChannelPreferencesTests {
    let key = ChannelKey(deviceSerial: "RFX-1", channel: "2")

    @Test func rememberedAcrossInstances() {
        let defaults = freshDefaults()
        let prefs = ChannelPreferences(defaults: defaults)
        prefs.setRole(.ambient, for: key)
        prefs.setLabel("  Pit  ", for: key)
        prefs.setIncluded(false, for: key)

        let reloaded = ChannelPreferences(defaults: defaults)
        #expect(reloaded.customization(for: key) == ProbeCustomization(role: .ambient, label: "Pit", isIncluded: false))
        #expect(!reloaded.isIncluded(key))
    }

    @Test func blankLabelClearsCustomName() {
        let prefs = ChannelPreferences(defaults: freshDefaults())
        prefs.setLabel("Pit", for: key)
        prefs.setLabel("   ", for: key)
        #expect(prefs.customization(for: key).label == nil)
    }

    @Test func defaultsAndReset() {
        let defaults = freshDefaults()
        let prefs = ChannelPreferences(defaults: defaults)
        #expect(prefs.isIncluded(key))
        prefs.setRole(.ambient, for: key)
        prefs.reset()
        #expect(prefs.customizations.isEmpty)
        #expect(ChannelPreferences(defaults: defaults).customizations.isEmpty)
    }
}

@MainActor
@Suite("App settings")
struct AppSettingsTests {
    @Test func defaultsIncludeFiveMinuteLeadAndKeepAwake() {
        let settings = AppSettings(defaults: freshDefaults())
        #expect(settings.almostDoneLeadMinutes == 5)
        #expect(settings.keepScreenOn)
        #expect(!settings.chartShowsElapsedTime)
    }

    @Test func resetRestoresInMemoryValues() {
        let defaults = freshDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.almostDoneLeadMinutes = 12
        settings.unit = .celsius
        settings.reset()
        #expect(settings.almostDoneLeadMinutes == 5)
        #expect(settings.unit == .fahrenheit)
        #expect(defaults.object(forKey: "settings.almostDoneLeadMinutes") == nil)
    }
}

@MainActor
@Suite("Cook resume")
struct CookResumeTests {
    @Test func resumesNewestUnfinishedCookAndClosesStrays() async throws {
        let t0 = Date().addingTimeInterval(-3600)
        let key = ChannelKey(deviceSerial: "RFX-CHICKEN", channel: "1")
        var stray = Cook(title: "Old", startedAt: t0.addingTimeInterval(-86_400),
                         probes: [CookProbe(key: key, label: "Chicken", role: .internal)])
        stray.append(Sample(time: t0.addingTimeInterval(-80_000), celsius: 50), to: key)
        let newest = Cook(title: "Current", startedAt: t0, probes: [CookProbe(key: key, label: "Chicken", role: .internal)])
        let store = InMemoryCookStore([stray, newest])
        let activities = NoLiveActivityController()
        let model = AppModel(
            launch: LaunchConfiguration(arguments: ["-OM_MOCK", "1", "-OM_SCENARIO", "chickenFast", "-OM_POLL", "60"]),
            settings: AppSettings(defaults: freshDefaults()), channels: ChannelPreferences(defaults: freshDefaults()),
            store: store, credentials: InMemoryCredentialStore(), notificationCenter: FakeNotificationCenter(),
            liveActivities: activities)

        await model.resumeUnfinishedCook()

        #expect(model.activeCook?.cook.id == newest.id)
        #expect(activities.reconciled.last == newest.id)
        #expect(activities.started.last == newest.id)
        let closed = try await store.load(id: stray.id)
        #expect(closed.endedAt == t0.addingTimeInterval(-80_000))
        if let cook = model.activeCook { await model.endCook(cook) }
    }

    @Test func nothingToResumeEndsOrphanedActivities() async {
        let activities = NoLiveActivityController()
        let model = AppModel(
            launch: LaunchConfiguration(arguments: ["-OM_MOCK", "1"]),
            settings: AppSettings(defaults: freshDefaults()), channels: ChannelPreferences(defaults: freshDefaults()),
            store: InMemoryCookStore(), credentials: InMemoryCredentialStore(), notificationCenter: FakeNotificationCenter(),
            liveActivities: activities)
        await model.resumeUnfinishedCook()
        #expect(model.activeCook == nil)
        #expect(activities.reconciled.allSatisfy { $0 == nil })
        #expect(!activities.reconciled.isEmpty)
    }
}
