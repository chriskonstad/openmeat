import CookCore
import CookSession
import Foundation
import Testing
import ThermoWorksMock
@testable import OpenMEAT

@MainActor
@Suite("App model (demo mode)")
struct AppModelTests {
    private func makeModel(scenario: String = "chickenFast") -> (AppModel, FakeNotificationCenter) {
        let defaults = UserDefaults(suiteName: "openmeat-tests-\(UUID().uuidString)")!
        let center = FakeNotificationCenter()
        let model = AppModel(
            launch: LaunchConfiguration(arguments: ["-OM_MOCK", "1", "-OM_SCENARIO", scenario, "-OM_TIME_SCALE", "600", "-OM_POLL", "0.1"]),
            settings: AppSettings(defaults: defaults),
            store: InMemoryCookStore(),
            credentials: InMemoryCredentialStore(),
            notificationCenter: center,
            makeLiveActivities: { NoLiveActivityController() })
        return (model, center)
    }

    @Test func mockLaunchSkipsSignIn() {
        let (model, _) = makeModel()
        #expect(model.phase == .ready)
        #expect(model.isDemo)
    }

    @Test func startCookPollsAndEndCookPersists() async throws {
        let (model, _) = makeModel()
        let devices = try await model.discover()
        #expect(devices.map(\.device.serial) == ["RFX-CHICKEN"])

        model.startCook(title: "Chicken", probes: ProbeDiscovery.probes(from: devices))
        let cook = try #require(model.activeCook)
        try await waitUntil { !(cook.snapshot.cook.series.values.first?.isEmpty ?? true) }

        await model.endCook(cook)
        #expect(model.activeCook == nil)
        let summaries = try await model.store.summaries()
        #expect(summaries.map(\.title) == ["Chicken"])
        #expect(summaries.first?.endedAt != nil)
    }

    @Test func signOutEndsActiveCookAndReturnsToLogin() async throws {
        let (model, _) = makeModel()
        model.startCook(title: "X", probes: ProbeDiscovery.probes(from: try await model.discover()))
        await model.signOut()
        #expect(model.activeCook == nil)
        #expect(model.phase == .signedOut)
    }

    /// Polls a condition without fixed sleeps longer than needed.
    private func waitUntil(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            try #require(ContinuousClock.now < deadline, "condition not met in time")
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
