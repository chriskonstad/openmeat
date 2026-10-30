import Foundation
import Testing
@testable import CookCore

@Suite("Alert planner")
struct AlertPlannerTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let meat = ChannelKey(deviceSerial: "RFX-1", channel: "1")
    let pit = ChannelKey(deviceSerial: "RFX-1", channel: "2")
    let planner = AlertPlanner(unit: .fahrenheit)

    private func cook(target: Double? = 203, lead: TimeInterval? = nil) -> Cook {
        Cook(title: "Brisket", startedAt: now.addingTimeInterval(-3600), probes: [
            CookProbe(key: meat, label: "Brisket", role: .internal, target: target.map { Temperature(fahrenheit: $0) }),
            CookProbe(key: pit, label: "Pit", role: .ambient, target: Temperature(fahrenheit: 250)),
        ], almostDoneLeadTime: lead)
    }

    private func estimating(in seconds: TimeInterval) -> [ChannelKey: Estimate] {
        [meat: Estimate(state: .estimating, eta: now.addingTimeInterval(seconds), method: .newton, confidence: 0.8)]
    }

    @Test func almostDoneFiresLeadTimeBeforeETA() throws {
        let alerts = planner.plan(cook: cook(), estimates: estimating(in: 3600), leadTime: 300, now: now)
        let almost = try #require(alerts.first { $0.kind == .almostDone })
        #expect(almost.fireDate == now.addingTimeInterval(3300))
        #expect(almost.title == "Brisket: ~5 min to go")
        #expect(almost.isEstimated)
        let reached = try #require(alerts.first { $0.kind == .targetReached })
        #expect(reached.fireDate == now.addingTimeInterval(3600))
    }

    @Test func perCookLeadTimeOverridesDefault() throws {
        let alerts = planner.plan(cook: cook(lead: 900), estimates: estimating(in: 3600), leadTime: 300, now: now)
        #expect(try #require(alerts.first { $0.kind == .almostDone }).fireDate == now.addingTimeInterval(2700))
    }

    @Test func insideLeadWindowFiresNow() throws {
        let alerts = planner.plan(cook: cook(), estimates: estimating(in: 120), leadTime: 300, now: now)
        #expect(try #require(alerts.first { $0.kind == .almostDone }).fireDate == now)
    }

    @Test func idsAreStableAcrossReplans() {
        let theCook = cook()
        let a = planner.plan(cook: theCook, estimates: estimating(in: 3600), leadTime: 300, now: now)
        let b = planner.plan(cook: theCook, estimates: estimating(in: 4000), leadTime: 300, now: now)
        #expect(Set(a.map(\.id)).count == 2)
        #expect(a.map(\.id) == b.map(\.id))
        #expect(a.map(\.fireDate) != b.map(\.fireDate))
    }

    @Test(arguments: [EstimateState.stalled, .warmingUp, .unavailable])
    func untrustworthyEstimatesProduceNoAlerts(_ state: EstimateState) {
        let estimates = [meat: Estimate(state: state, eta: now.addingTimeInterval(600))]
        #expect(planner.plan(cook: cook(), estimates: estimates, leadTime: 300, now: now).isEmpty)
    }

    @Test func reachedFiresImmediatelyAndIsNotEstimated() throws {
        let alerts = planner.plan(cook: cook(), estimates: [meat: Estimate(state: .reached)], leadTime: 300, now: now)
        let alert = try #require(alerts.only)
        #expect(alert.kind == .targetReached)
        #expect(alert.fireDate == now)
        #expect(!alert.isEstimated)
        #expect(alert.body == "Reached 203°F.")
    }

    @Test func noTargetOrEndedCookProducesNothing() {
        #expect(planner.plan(cook: cook(target: nil), estimates: estimating(in: 3600), leadTime: 300, now: now).isEmpty)
        var ended = cook()
        ended.endedAt = now
        #expect(planner.plan(cook: ended, estimates: estimating(in: 3600), leadTime: 300, now: now).isEmpty)
    }

    @Test func pastETAProducesNothing() {
        #expect(planner.plan(cook: cook(), estimates: estimating(in: -10), leadTime: 300, now: now).isEmpty)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
