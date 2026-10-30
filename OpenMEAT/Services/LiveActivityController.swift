import ActivityKit
import CookCore
import CookSession
import Foundation

extension CookActivityAttributes.ContentState {
    /// Pure mapping from a session snapshot — unit tested.
    init(snapshot: SessionSnapshot, unit: TemperatureUnit) {
        let probe = snapshot.primaryProbe
        let series = probe.flatMap { snapshot.cook.series[$0.key] }
        let estimate = probe.flatMap { snapshot.estimates[$0.key] }
        let status: String? = switch estimate?.state {
        case .warmingUp: "Calculating…"
        case .stalled: "Stall"
        case .reached: "Done"
        case .unavailable: probe?.target == nil ? nil : "No estimate"
        case .estimating, nil: nil
        }
        self.init(
            probeLabel: probe?.label ?? snapshot.cook.title,
            currentCelsius: series?.last?.celsius,
            targetCelsius: probe?.target?.celsius,
            startCelsius: series?.first?.celsius,
            eta: estimate?.state == .estimating ? estimate?.eta : nil,
            status: status,
            unit: unit.rawValue,
            isEnded: !snapshot.cook.isActive
        )
    }
}

@MainActor
protocol LiveActivityControlling: AnyObject {
    func start(cook: Cook, state: CookActivityAttributes.ContentState)
    func update(_ state: CookActivityAttributes.ContentState)
    func end(_ state: CookActivityAttributes.ContentState)
}

/// ActivityKit implementation. Throttles updates (ActivityKit budgets frequent updates).
@MainActor
final class LiveActivityController: LiveActivityControlling {
    private var activityID: String?
    private var lastState: CookActivityAttributes.ContentState?
    private var lastUpdate: Date = .distantPast
    private let minimumInterval: TimeInterval

    init(minimumInterval: TimeInterval = 15) {
        self.minimumInterval = minimumInterval
    }

    func start(cook: Cook, state: CookActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, activityID == nil else { return }
        let attributes = CookActivityAttributes(cookID: cook.id, title: cook.title, startedAt: cook.startedAt)
        activityID = (try? Activity.request(attributes: attributes, content: .init(state: state, staleDate: nil)))?.id
        lastState = state
    }

    func update(_ state: CookActivityAttributes.ContentState) {
        guard let activityID, state != lastState, Date().timeIntervalSince(lastUpdate) >= minimumInterval else { return }
        lastState = state
        lastUpdate = Date()
        Task { await Self.push(activityID, state, end: false) }
    }

    func end(_ state: CookActivityAttributes.ContentState) {
        guard let activityID else { return }
        self.activityID = nil
        Task { await Self.push(activityID, state, end: true) }
    }

    /// Activity isn't Sendable, so look it up off the main actor by id.
    private nonisolated static func push(_ id: String, _ state: CookActivityAttributes.ContentState, end: Bool) async {
        guard let activity = Activity<CookActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        if end {
            await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(30 * 60)))
        } else {
            await activity.update(.init(state: state, staleDate: Date().addingTimeInterval(15 * 60)))
        }
    }
}

/// No-op (tests, demo when activities are disabled).
@MainActor
final class NoLiveActivityController: LiveActivityControlling {
    private(set) var states: [CookActivityAttributes.ContentState] = []
    func start(cook: Cook, state: CookActivityAttributes.ContentState) { states.append(state) }
    func update(_ state: CookActivityAttributes.ContentState) { states.append(state) }
    func end(_ state: CookActivityAttributes.ContentState) { states.append(state) }
}
