import Foundation

public struct PlannedAlert: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case almostDone
        case targetReached
    }

    /// Stable per cook/probe/kind so rescheduling replaces rather than duplicates.
    public var id: String
    public var kind: Kind
    public var probe: ChannelKey
    public var fireDate: Date
    public var title: String
    public var body: String
    /// True when based on an estimate rather than an observed crossing.
    public var isEstimated: Bool

    public init(id: String, kind: Kind, probe: ChannelKey, fireDate: Date, title: String, body: String, isEstimated: Bool) {
        self.id = id
        self.kind = kind
        self.probe = probe
        self.fireDate = fireDate
        self.title = title
        self.body = body
        self.isEstimated = isEstimated
    }
}

/// Pure function from cook state + estimates to the notifications that should be pending.
/// The app's NotificationScheduler diffs this against what's scheduled/delivered.
public struct AlertPlanner: Sendable {
    public var unit: TemperatureUnit

    public init(unit: TemperatureUnit) {
        self.unit = unit
    }

    public func plan(cook: Cook, estimates: [ChannelKey: Estimate], leadTime: TimeInterval, now: Date) -> [PlannedAlert] {
        guard cook.isActive else { return [] }
        let lead = cook.almostDoneLeadTime ?? leadTime
        var alerts: [PlannedAlert] = []

        for probe in cook.probes where probe.role == .internal {
            guard let target = probe.target, let estimate = estimates[probe.key] else { continue }
            let targetText = target.formatted(unit)
            let baseID = "\(cook.id.uuidString)/\(probe.key)"

            switch estimate.state {
            case .reached:
                alerts.append(PlannedAlert(
                    id: "\(baseID)/reached", kind: .targetReached, probe: probe.key, fireDate: now,
                    title: "\(probe.label) is done", body: "Reached \(targetText).", isEstimated: false))

            case .estimating:
                guard let eta = estimate.eta, eta > now else { continue }
                let minutes = Int((lead / 60).rounded())
                let almostDoneAt = eta.addingTimeInterval(-lead)
                alerts.append(PlannedAlert(
                    id: "\(baseID)/almostDone", kind: .almostDone, probe: probe.key,
                    fireDate: max(almostDoneAt, now),
                    title: "\(probe.label): ~\(minutes) min to go",
                    body: "Should reach \(targetText) around \(eta.formatted(date: .omitted, time: .shortened)).",
                    isEstimated: true))
                alerts.append(PlannedAlert(
                    id: "\(baseID)/reached", kind: .targetReached, probe: probe.key, fireDate: eta,
                    title: "\(probe.label) should be done", body: "Estimated to reach \(targetText). Check it!",
                    isEstimated: true))

            case .stalled, .warmingUp, .unavailable:
                // Suppress ETA-driven alerts when the estimate isn't trustworthy.
                continue
            }
        }
        return alerts
    }
}
