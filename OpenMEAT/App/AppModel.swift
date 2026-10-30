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

    /// Speed of "Try demo mode" from the login screen, so the graph visibly moves.
    static let interactiveDemoTimeScale: Double = 30

    private(set) var phase: Phase = .signedOut
    private(set) var signInError: String?
    private(set) var isDemo = false
    private(set) var activeCook: LiveCookModel?

    let settings: AppSettings
    let channels: ChannelPreferences
    /// Real and demo cooks are stored apart, so simulated cooks never show up in (or get resumed from)
    /// real history.
    private let realStore: any CookStore
    private let demoStore: any CookStore
    var store: any CookStore { isDemo ? demoStore : realStore }
    let launch: LaunchConfiguration
    private let credentials: any CredentialStoring
    private let notificationCenter: any NotificationCenterClient
    private let notifications: NotificationScheduler
    private let liveActivities: any LiveActivityControlling
    private(set) var service: (any ThermoWorksService)?
    private(set) var timeSource: any TimeSource = SystemTimeSource()
    private var timeScale: Double = 1

    init(
        launch: LaunchConfiguration = .current,
        settings: AppSettings = AppSettings(),
        channels: ChannelPreferences = ChannelPreferences(),
        store: (any CookStore)? = nil,
        credentials: any CredentialStoring = KeychainCredentialStore(),
        notificationCenter: any NotificationCenterClient = SystemNotificationCenter(),
        liveActivities: any LiveActivityControlling = LiveActivityController()
    ) {
        self.launch = launch
        self.settings = settings
        self.channels = channels
        self.credentials = credentials
        self.notificationCenter = notificationCenter
        self.notifications = NotificationScheduler(center: notificationCenter)
        self.liveActivities = liveActivities
        self.realStore = store ?? Self.defaultStore(folder: "Cooks", reset: launch.reset)
        self.demoStore = store ?? Self.defaultStore(folder: "DemoCooks", reset: true)
        if launch.reset {
            settings.reset()
            channels.reset()
            credentials.clear()
        }
        if launch.useMock {
            enterDemo(timeScale: launch.timeScale)
            if launch.autoStart {
                Task { await self.startDemoCook() }
            }
        } else if let session = credentials.load() {
            restore(session)
        } else {
            liveActivities.reconcile(activeCookID: nil)
        }
    }

    private static func defaultStore(folder: String, reset: Bool) -> any CookStore {
        let dir = URL.applicationSupportDirectory.appending(path: folder)
        if reset { try? FileManager.default.removeItem(at: dir) }
        return (try? FileCookStore(directory: dir)) ?? InMemoryCookStore()
    }

    // MARK: Auth

    func signIn(email: String, password: String) async {
        phase = .signingIn
        signInError = nil
        let credentials = credentials
        do {
            let result = try await LiveThermoWorksService.signIn(email: email, password: password,
                                                                 http: RecordingHTTPClient(base: URLSessionHTTPClient()),
                                                                 onRefresh: { refreshed in
                // Persist rotated tokens.
                if var stored = credentials.load() {
                    stored.credentials = refreshed
                    credentials.save(stored)
                }
            })
            credentials.save(StoredSession(credentials: result.credentials, project: result.project))
            becomeReady(service: result.service, timeSource: SystemTimeSource(), scale: 1, demo: false)
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
        becomeReady(service: LiveThermoWorksService(project: stored.project, tokens: tokens,
                                                    http: RecordingHTTPClient(base: URLSessionHTTPClient())),
                    timeSource: SystemTimeSource(), scale: 1, demo: false)
    }

    /// Simulated probes; no account needed. Also used by UI tests (`-OM_MOCK 1`).
    func enterDemo(timeScale: Double = AppModel.interactiveDemoTimeScale) {
        let clock = ScaledTimeSource(anchor: Date(), scale: timeScale)
        becomeReady(service: MockThermoWorksService(scenario: launch.scenario, timeSource: clock),
                    timeSource: clock, scale: timeScale, demo: true)
    }

    private func becomeReady(service: any ThermoWorksService, timeSource: any TimeSource, scale: Double, demo: Bool) {
        self.service = service
        self.timeSource = timeSource
        self.timeScale = scale
        isDemo = demo
        signInError = nil
        phase = .ready
        // A simulated cook can't be resumed against a fresh simulator timeline.
        if demo {
            liveActivities.reconcile(activeCookID: nil)
        } else {
            Task {
                await resumeUnfinishedCook()
                // Capture the real device/channel layout for diagnostics (SPEC §3.3).
                _ = try? await discover()
            }
        }
    }

    private func startDemoCook() async {
        guard let devices = try? await discover() else { return }
        var probes = ProbeDiscovery.probes(from: devices, customizations: channels.customizations)
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
        guard activeCook == nil else { return }
        let cook = Cook(title: title.isEmpty ? "Cook" : title, startedAt: timeSource.now, probes: probes)
        run(cook)
        Task { [notificationCenter] in _ = await notificationCenter.requestAuthorization() }
    }

    /// iOS may terminate the app during a long cook; pick the newest unfinished cook back up and
    /// close out any older strays so they appear in History.
    func resumeUnfinishedCook() async {
        guard activeCook == nil else { return }
        let unfinished = ((try? await store.summaries()) ?? []).filter { $0.endedAt == nil }
        guard let newest = unfinished.first, var cook = try? await store.load(id: newest.id) else {
            liveActivities.reconcile(activeCookID: nil)
            return
        }
        for stray in unfinished.dropFirst() {
            guard var old = try? await store.load(id: stray.id) else { continue }
            old.endedAt = old.series.values.compactMap(\.last?.time).max() ?? old.startedAt
            try? await store.save(old)
        }
        liveActivities.reconcile(activeCookID: cook.id)
        cook.endedAt = nil
        run(cook)
    }

    private func run(_ cook: Cook) {
        guard let service else { return }
        var options = LiveCookSession.Options()
        let poll = launch.pollInterval ?? settings.pollIntervalSeconds
        options.pollInterval = .milliseconds(Int(poll * 1000))
        // In scaled time, staleness is measured in simulated seconds.
        options.staleAfter = max(180, poll * timeScale * 3)
        let session = LiveCookSession(cook: cook, service: service, store: store, timeSource: timeSource, options: options)
        let clock = timeSource
        let model = LiveCookModel(
            session: session, cook: cook, settings: settings, timeSource: timeSource,
            notifications: notifications,
            liveActivities: settings.liveActivitiesEnabled ? liveActivities : NoLiveActivityController(),
            wallClock: { date in (clock as? ScaledTimeSource)?.wallClock(for: date) ?? date })
        activeCook = model
        model.start()
    }

    func endCook(_ model: LiveCookModel) async {
        await model.end()
        activeCook = nil
    }

    // MARK: Background

    /// Called from a BGAppRefreshTask or when the app is about to be suspended.
    func performBackgroundRefresh() async {
        await activeCook?.backgroundRefresh()
    }

    func prepareForBackground() async {
        await activeCook?.prepareForBackground()
    }
}
