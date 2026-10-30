import CookCore
import CookSession
import Foundation
import Observation
import ThermoWorksCloud
import ThermoWorksMock

/// Root app state and dependency container.
@MainActor @Observable
final class AppModel {
    enum Phase: Equatable {
        case signedOut
        case signingIn
        case ready
    }

    private(set) var phase: Phase = .signedOut
    private(set) var signInError: String?
    private(set) var isDemo = false
    private(set) var activeCook: LiveCookModel?

    let settings: AppSettings
    let store: any CookStore
    let launch: LaunchConfiguration
    private let credentials: any CredentialStoring
    private let notificationCenter: any NotificationCenterClient
    private let notifications: NotificationScheduler
    private let makeLiveActivities: @MainActor () -> any LiveActivityControlling
    private(set) var service: (any ThermoWorksService)?
    private(set) var timeSource: any TimeSource = SystemTimeSource()

    init(
        launch: LaunchConfiguration = .current,
        settings: AppSettings = AppSettings(),
        store: (any CookStore)? = nil,
        credentials: any CredentialStoring = KeychainCredentialStore(),
        notificationCenter: any NotificationCenterClient = SystemNotificationCenter(),
        makeLiveActivities: @escaping @MainActor () -> any LiveActivityControlling = { LiveActivityController() }
    ) {
        self.launch = launch
        self.settings = settings
        self.credentials = credentials
        self.notificationCenter = notificationCenter
        self.notifications = NotificationScheduler(center: notificationCenter)
        self.makeLiveActivities = makeLiveActivities
        self.store = store ?? Self.defaultStore(reset: launch.reset)
        if launch.reset {
            settings.reset()
            credentials.clear()
        }
        if launch.useMock {
            enterDemo()
            if launch.autoStart {
                Task { await self.startDemoCook() }
            }
        } else if let session = credentials.load() {
            restore(session)
        }
    }

    private static func defaultStore(reset: Bool) -> any CookStore {
        let dir = URL.applicationSupportDirectory.appending(path: "Cooks")
        if reset { try? FileManager.default.removeItem(at: dir) }
        return (try? FileCookStore(directory: dir)) ?? InMemoryCookStore()
    }

    // MARK: Auth

    func signIn(email: String, password: String) async {
        phase = .signingIn
        signInError = nil
        let credentials = credentials
        do {
            let result = try await LiveThermoWorksService.signIn(email: email, password: password, onRefresh: { refreshed in
                // Persist rotated tokens.
                if var stored = credentials.load() {
                    stored.credentials = refreshed
                    credentials.save(stored)
                }
            })
            credentials.save(StoredSession(credentials: result.credentials, project: result.project))
            service = result.service
            timeSource = SystemTimeSource()
            isDemo = false
            phase = .ready
        } catch {
            signInError = error.localizedDescription
            phase = .signedOut
        }
    }

    private func restore(_ stored: StoredSession) {
        let credentials = credentials
        let authenticator = ThermoWorksAuthenticator(http: URLSessionHTTPClient())
        let tokens = TokenManager(credentials: stored.credentials, authenticator: authenticator, onRefresh: { refreshed in
            credentials.save(StoredSession(credentials: refreshed, project: stored.project))
        })
        service = LiveThermoWorksService(project: stored.project, tokens: tokens, http: URLSessionHTTPClient())
        phase = .ready
    }

    /// Simulated probes; no account needed. Also used by UI tests (`-OM_MOCK 1`).
    func enterDemo() {
        let clock = ScaledTimeSource(anchor: Date(), scale: launch.timeScale)
        timeSource = clock
        service = MockThermoWorksService(scenario: launch.scenario, timeSource: clock)
        isDemo = true
        signInError = nil
        phase = .ready
    }

    private func startDemoCook() async {
        guard let devices = try? await discover() else { return }
        var probes = ProbeDiscovery.probes(from: devices)
        for i in probes.indices where probes[i].role == .internal {
            probes[i].target = Temperature(fahrenheit: 203)
        }
        startCook(title: devices.first?.device.label ?? "Demo", probes: probes)
    }

    func signOut() async {
        if let activeCook { await endCook(activeCook) }
        credentials.clear()
        service = nil
        isDemo = false
        phase = .signedOut
    }

    // MARK: Cooks

    func discover() async throws -> [DiscoveredDevice] {
        guard let service else { return [] }
        return try await ProbeDiscovery.discover(using: service)
    }

    func startCook(title: String, probes: [CookProbe]) {
        guard let service, activeCook == nil else { return }
        let cook = Cook(title: title.isEmpty ? "Cook" : title, startedAt: timeSource.now, probes: probes)
        var options = LiveCookSession.Options()
        let poll = launch.pollInterval ?? settings.pollIntervalSeconds
        options.pollInterval = .milliseconds(Int(poll * 1000))
        // In scaled time, staleness is measured in simulated seconds.
        options.staleAfter = max(180, poll * launch.timeScale * 3)
        let session = LiveCookSession(cook: cook, service: service, store: store, timeSource: timeSource, options: options)
        let model = LiveCookModel(
            session: session, cook: cook, settings: settings, timeSource: timeSource,
            notifications: notifications,
            liveActivities: settings.liveActivitiesEnabled ? makeLiveActivities() : NoLiveActivityController())
        activeCook = model
        model.start()
        Task { [notificationCenter] in _ = await notificationCenter.requestAuthorization() }
    }

    func endCook(_ model: LiveCookModel) async {
        await model.end()
        activeCook = nil
    }
}
