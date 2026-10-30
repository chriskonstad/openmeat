import CookCore
import CookSession
import Foundation
import Observation

/// UI-facing wrapper around a `LiveCookSession`: mirrors snapshots and fans them out to
/// notifications and the Live Activity.
@MainActor @Observable
final class LiveCookModel {
    private(set) var snapshot: SessionSnapshot
    let settings: AppSettings
    let timeSource: any TimeSource

    private let session: LiveCookSession
    private let notifications: NotificationScheduler
    private let liveActivities: any LiveActivityControlling
    private var observeTask: Task<Void, Never>?

    init(session: LiveCookSession, cook: Cook, settings: AppSettings, timeSource: any TimeSource,
         notifications: NotificationScheduler, liveActivities: any LiveActivityControlling) {
        self.session = session
        self.settings = settings
        self.timeSource = timeSource
        self.notifications = notifications
        self.liveActivities = liveActivities
        self.snapshot = SessionSnapshot(cook: cook, estimates: [:], staleChannels: [], lastPoll: nil, lastError: nil, now: timeSource.now)
    }

    var cook: Cook { snapshot.cook }

    func start() {
        liveActivities.start(cook: cook, state: .init(snapshot: snapshot, unit: settings.unit))
        observeTask = Task { [weak self, session] in
            for await snap in await session.snapshots() {
                await self?.apply(snap)
            }
        }
        Task { await session.start() }
    }

    private func apply(_ snap: SessionSnapshot) async {
        snapshot = snap
        liveActivities.update(.init(snapshot: snap, unit: settings.unit))
        let alerts = AlertPlanner(unit: settings.unit)
            .plan(cook: snap.cook, estimates: snap.estimates, leadTime: settings.almostDoneLeadTime, now: snap.now)
        await notifications.sync(alerts, now: snap.now)
    }

    // MARK: Intents

    func setTarget(_ target: Temperature?, for key: ChannelKey) {
        Task { await session.setTarget(target, for: key) }
    }

    func addNote(_ text: String, isQuickNote: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { await session.addNote(trimmed, isQuickNote: isQuickNote) }
    }

    func deleteNote(_ id: UUID) {
        Task { await session.deleteNote(id: id) }
    }

    func setLeadTimeOverride(_ minutes: Int?) {
        Task { await session.setAlmostDoneLeadTime(minutes.map { TimeInterval($0 * 60) }) }
    }

    func refreshNow() async {
        await session.pollOnce()
    }

    func end() async {
        observeTask?.cancel()
        if let ended = try? await session.end() {
            snapshot.cook = ended
        }
        notifications.cancelAll()
        liveActivities.end(.init(snapshot: snapshot, unit: settings.unit))
    }
}
