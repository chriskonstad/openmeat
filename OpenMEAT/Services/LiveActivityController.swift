import ActivityKit
import CookCore
import CookSession
import Foundation

extension CookActivityAttributes.ContentState {
    /// Pure mapping from a session snapshot — unit tested.
    /// `wallClock` converts the session's timeline to real time (identity except in accelerated demo mode),
    /// because Live Activity timers run on the system clock.
    init(snapshot: SessionSnapshot, unit: TemperatureUnit, wallClock: (Date) -> Date = { $0 }) {
        let probe = snapshot.primaryProbe
        let series = probe.flatMap { snapshot.cook.series[$0.key] }
        let estimate = probe.flatMap { snapshot.estimates[$0.key] }
        let status: String? = switch estimate?.state {
        case .warmingUp: "Calculating…"
        case .stalled: "Stall"
        case .reached: nil  // shown as a count-up from `targetReachedAt`
        case .unavailable: probe?.target == nil ? nil : "No estimate"
        case .estimating, nil: nil
        }
        self.init(
            probeLabel: probe?.label ?? snapshot.cook.title,
            currentCelsius: series?.last?.celsius,
            targetCelsius: probe?.target?.celsius,
            startCelsius: series?.first?.celsius,
            eta: estimate?.state == .estimating ? estimate?.eta.map(wallClock) : nil,
            targetReachedAt: probe.flatMap { snapshot.cook.targetReachedAt($0.key) }.map(wallClock),
            status: status,
            unit: unit.rawValue,
            updatedAt: wallClock(snapshot.latestReadingTime ?? snapshot.now),
            isDataStale: snapshot.isStale,
            isEnded: !snapshot.cook.isActive
        )
    }
}

@MainActor
protocol LiveActivityControlling: AnyObject {
    /// `startedAt` is wall-clock time.
    func start(cookID: UUID, title: String, startedAt: Date, state: CookActivityAttributes.ContentState)
    /// `force` bypasses throttling (background refresh, about to suspend).
    func update(_ state: CookActivityAttributes.ContentState, force: Bool)
    func end(_ state: CookActivityAttributes.ContentState)
    /// Ends activities left behind by a previous process (crash, termination), except the
    /// one for `activeCookID`, which is adopted so updates continue on the same activity.
    func reconcile(activeCookID: UUID?)
}

/// ActivityKit implementation. Throttles foreground updates (the system coalesces frequent updates anyway).
@MainActor
final class LiveActivityController: LiveActivityControlling {
    private var activityID: String?
    private var lastState: CookActivityAttributes.ContentState?
    private var lastUpdate: Date = .distantPast
    private let minimumInterval: TimeInterval

    init(minimumInterval: TimeInterval = 10) {
        self.minimumInterval = minimumInterval
    }

    /// Updates keep the activity "fresh" this long; past it the widget shows "Updated hh:mm".
    static let staleAfter: TimeInterval = 20 * 60

    func start(cookID: UUID, title: String, startedAt: Date, state: CookActivityAttributes.ContentState) {
        let enabled = ActivityAuthorizationInfo().areActivitiesEnabled
        Diagnostics.log("LA start cook=\(cookID) enabled=\(enabled) existing=\(Activity<CookActivityAttributes>.activities.count)")
        guard enabled else { return }
        reconcile(activeCookID: cookID)
        if activityID != nil {
            Diagnostics.log("LA adopted existing activity \(activityID ?? "")")
            update(state, force: true)
            return
        }
        let attributes = CookActivityAttributes(cookID: cookID, title: title, startedAt: startedAt)
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter)))
            activityID = activity.id
            Diagnostics.log("LA requested \(activity.id) state=\(activity.activityState)")
        } catch {
            Diagnostics.log("LA request failed: \(error)")
        }
        lastState = state
        lastUpdate = Date()
    }

    func update(_ state: CookActivityAttributes.ContentState, force: Bool) {
        guard let activityID, state != lastState else { return }
        guard force || Date().timeIntervalSince(lastUpdate) >= minimumInterval else { return }
        lastState = state
        lastUpdate = Date()
        Task { await Self.push(activityID, state, end: false) }
    }

    func end(_ state: CookActivityAttributes.ContentState) {
        guard let activityID else { return }
        Diagnostics.log("LA end \(activityID)")
        self.activityID = nil
        lastState = nil
        Task { await Self.push(activityID, state, end: true) }
    }

    func reconcile(activeCookID: UUID?) {
        for activity in Activity<CookActivityAttributes>.activities {
            if let activeCookID, activity.attributes.cookID == activeCookID, activity.activityState == .active {
                activityID = activity.id
            } else {
                let id = activity.id
                Diagnostics.log("LA reconcile: ending stray \(id) for cook \(activity.attributes.cookID) (active cook \(activeCookID?.uuidString ?? "none"))")
                Task { await Self.dismiss(id) }
            }
        }
    }

    // Activity isn't Sendable, so it's looked up off the main actor by id.
    private nonisolated static func push(_ id: String, _ state: CookActivityAttributes.ContentState, end: Bool) async {
        guard let activity = Activity<CookActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        if end {
            await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(30 * 60)))
        } else {
            await activity.update(.init(state: state, staleDate: Date().addingTimeInterval(staleAfter)))
        }
    }

    private nonisolated static func dismiss(_ id: String) async {
        guard let activity = Activity<CookActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
    }
}

/// Records calls instead of talking to ActivityKit (tests; Live Activities disabled).
@MainActor
final class NoLiveActivityController: LiveActivityControlling {
    private(set) var started: [UUID] = []
    private(set) var states: [CookActivityAttributes.ContentState] = []
    private(set) var reconciled: [UUID?] = []
    func start(cookID: UUID, title: String, startedAt: Date, state: CookActivityAttributes.ContentState) {
        started.append(cookID)
        states.append(state)
    }
    func update(_ state: CookActivityAttributes.ContentState, force: Bool) { states.append(state) }
    func end(_ state: CookActivityAttributes.ContentState) { states.append(state) }
    func reconcile(activeCookID: UUID?) { reconciled.append(activeCookID) }
}
