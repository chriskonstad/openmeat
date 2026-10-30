import BackgroundTasks
import UIKit

/// Opportunistic background polling (SPEC §4.2).
///
/// iOS does not let a suspended app run timers. The levers we have:
/// - `BGAppRefreshTask`: we *request* a wake ~1 min out; iOS decides when (often 15+ min, based on
///   how much the user uses the app, battery, etc.). Each wake polls, updates the Live Activity and
///   reschedules alerts, then requests the next wake.
/// - A short `beginBackgroundTask` window when leaving the app to push the freshest state.
/// - The Live Activity's own timers (elapsed, ETA countdown, progress) keep moving between updates.
/// Truly per-minute background updates need ActivityKit push from a server (the optional relay).
@MainActor
enum BackgroundRefresh {
    static let taskIdentifier = "org.openmeat.OpenMEAT.refresh"
    static let requestedInterval: TimeInterval = 60

    /// Must be called before the app finishes launching.
    static func register(model: @escaping @MainActor () -> AppModel?) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: .main) { task in
            MainActor.assumeIsolated {
                handle(task, model: model())
            }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(requestedInterval)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
    }

    private static func handle(_ task: BGTask, model: AppModel?) {
        guard let model, model.activeCook != nil else {
            task.setTaskCompleted(success: true)
            return
        }
        schedule()
        let work = Task { @MainActor in
            await model.performBackgroundRefresh()
        }
        task.expirationHandler = { work.cancel() }
        Task { @MainActor in
            await work.value
            task.setTaskCompleted(success: !work.isCancelled)
        }
    }

    /// Called when the scene backgrounds: push the latest state within a short grace window.
    static func didEnterBackground(_ model: AppModel) {
        guard model.activeCook != nil else { return }
        schedule()
        let application = UIApplication.shared
        var identifier: UIBackgroundTaskIdentifier = .invalid
        identifier = application.beginBackgroundTask(withName: "OpenMEAT.flush") {
            application.endBackgroundTask(identifier)
        }
        Task { @MainActor in
            await model.prepareForBackground()
            application.endBackgroundTask(identifier)
        }
    }
}
