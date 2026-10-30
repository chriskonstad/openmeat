import CookCore
import Foundation
import Synchronization
import Testing
@testable import OpenMEAT

final class FakeNotificationCenter: NotificationCenterClient {
    struct Added: Equatable { var id: String; var title: String; var delay: TimeInterval }
    private let state = Mutex<(added: [Added], removed: [String])>(([], []))

    var added: [Added] { state.withLock { $0.added } }
    var removed: [String] { state.withLock { $0.removed } }

    func requestAuthorization() async -> Bool { true }

    func add(id: String, title: String, body: String, fireIn seconds: TimeInterval) async throws {
        state.withLock { $0.added.append(Added(id: id, title: title, delay: seconds)) }
    }

    func removePending(ids: [String]) {
        state.withLock { $0.removed.append(contentsOf: ids) }
    }
}

@MainActor
@Suite("Notification scheduler")
struct NotificationSchedulerTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let probe = ChannelKey(deviceSerial: "RFX", channel: "1")

    private func alert(_ id: String, in seconds: TimeInterval, kind: PlannedAlert.Kind = .almostDone) -> PlannedAlert {
        PlannedAlert(id: id, kind: kind, probe: probe, fireDate: now.addingTimeInterval(seconds),
                     title: id, body: "", isEstimated: true)
    }

    @Test func schedulesNewAlerts() async {
        let center = FakeNotificationCenter()
        let scheduler = NotificationScheduler(center: center)
        await scheduler.sync([alert("a", in: 600)], now: now)
        #expect(center.added == [.init(id: "a", title: "a", delay: 600)])
    }

    @Test func smallETAJitterDoesNotReschedule() async {
        let center = FakeNotificationCenter()
        let scheduler = NotificationScheduler(center: center, rescheduleThreshold: 60)
        await scheduler.sync([alert("a", in: 600)], now: now)
        await scheduler.sync([alert("a", in: 630)], now: now)
        #expect(center.added.count == 1)
        await scheduler.sync([alert("a", in: 900)], now: now)
        #expect(center.added.count == 2)
    }

    @Test func removesAlertsNoLongerPlanned() async {
        let center = FakeNotificationCenter()
        let scheduler = NotificationScheduler(center: center)
        await scheduler.sync([alert("a", in: 600), alert("b", in: 900)], now: now)
        await scheduler.sync([alert("b", in: 900)], now: now)
        #expect(center.removed == ["a"])
        #expect(scheduler.scheduled.keys.sorted() == ["b"])
    }

    @Test func immediateAlertsFireOnce() async {
        let center = FakeNotificationCenter()
        let scheduler = NotificationScheduler(center: center)
        let reached = alert("reached", in: 0, kind: .targetReached)
        await scheduler.sync([reached], now: now)
        await scheduler.sync([reached], now: now.addingTimeInterval(15))
        #expect(center.added.map(\.id) == ["reached"])
    }

    @Test func firedScheduledAlertsAreNotRescheduled() async {
        let center = FakeNotificationCenter()
        let scheduler = NotificationScheduler(center: center)
        await scheduler.sync([alert("a", in: 60)], now: now)
        // Time passes beyond the fire date; planner still emits it (ETA slipped).
        await scheduler.sync([alert("a", in: 300)], now: now.addingTimeInterval(120))
        #expect(center.added.count == 1)
        #expect(scheduler.delivered.contains("a"))
    }

    @Test func cancelAllClearsPending() async {
        let center = FakeNotificationCenter()
        let scheduler = NotificationScheduler(center: center)
        await scheduler.sync([alert("a", in: 600)], now: now)
        scheduler.cancelAll()
        #expect(center.removed == ["a"])
        #expect(scheduler.scheduled.isEmpty)
    }
}
