import CookCore
import Foundation
import UserNotifications

/// The subset of UNUserNotificationCenter we use — faked in tests.
protocol NotificationCenterClient: Sendable {
    func requestAuthorization() async -> Bool
    func add(id: String, title: String, body: String, fireIn seconds: TimeInterval) async throws
    func removePending(ids: [String])
}

struct SystemNotificationCenter: NotificationCenterClient {
    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func add(id: String, title: String, body: String, fireIn seconds: TimeInterval) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        // A trigger interval must be > 0; nil trigger delivers immediately.
        let trigger = seconds >= 1 ? UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false) : nil
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    func removePending(ids: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }
}

/// Keeps pending local notifications in sync with `AlertPlanner` output.
/// - Reschedules an alert only when its fire date moves by more than `rescheduleThreshold`.
/// - Never re-delivers an alert that already fired (e.g. "target reached").
@MainActor
final class NotificationScheduler {
    private let center: any NotificationCenterClient
    private let rescheduleThreshold: TimeInterval
    private(set) var scheduled: [String: Date] = [:]
    private(set) var delivered: Set<String> = []

    init(center: any NotificationCenterClient, rescheduleThreshold: TimeInterval = 60) {
        self.center = center
        self.rescheduleThreshold = rescheduleThreshold
    }

    func sync(_ alerts: [PlannedAlert], now: Date) async {
        let planned = Dictionary(alerts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Fired by now → considered delivered.
        for (id, date) in scheduled where date <= now {
            delivered.insert(id)
            scheduled[id] = nil
        }
        // Drop pending alerts that are no longer planned (target cleared, stall, cook ended).
        let stale = scheduled.keys.filter { planned[$0] == nil }
        if !stale.isEmpty {
            center.removePending(ids: Array(stale))
            for id in stale { scheduled[id] = nil }
        }

        for alert in alerts where !delivered.contains(alert.id) {
            if let existing = scheduled[alert.id], abs(existing.timeIntervalSince(alert.fireDate)) < rescheduleThreshold {
                continue
            }
            let delay = alert.fireDate.timeIntervalSince(now)
            do {
                try await center.add(id: alert.id, title: alert.title, body: alert.body, fireIn: delay)
                if delay < 1 {
                    delivered.insert(alert.id)
                    scheduled[alert.id] = nil
                } else {
                    scheduled[alert.id] = alert.fireDate
                }
            } catch {
                // Leave unscheduled; the next sync retries.
            }
        }
    }

    /// Cancel everything for a finished cook.
    func cancelAll() {
        center.removePending(ids: Array(scheduled.keys))
        scheduled.removeAll()
        delivered.removeAll()
    }
}
