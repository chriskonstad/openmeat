import SwiftUI

@main
struct OpenMEATApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        if LaunchConfiguration.current.disableAnimations {
            UIView.setAnimationsEnabled(false)
        }
        let model = AppModel()
        _model = State(initialValue: model)
        BackgroundRefresh.register { [weak model] in model }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.settings)
                .environment(model.channels)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                BackgroundRefresh.didEnterBackground(model)
            case .active:
                // Catch up right away after being suspended.
                Task { await model.activeCook?.refreshNow() }
            default:
                break
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Group {
            switch model.phase {
            case .signedOut, .signingIn:
                LoginView()
            case .ready:
                MainTabView()
            }
        }
        .onChange(of: model.activeCook != nil && settings.keepScreenOn, initial: true) { _, keepAwake in
            UIApplication.shared.isIdleTimerDisabled = keepAwake
        }
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            Tab("Cook", systemImage: "flame") {
                LiveTab()
            }
            .accessibilityIdentifier(AccessibilityID.Tabs.live)
            Tab("History", systemImage: "clock.arrow.circlepath") {
                HistoryView()
            }
            .accessibilityIdentifier(AccessibilityID.Tabs.history)
            Tab("Settings", systemImage: "gearshape") {
                SettingsView()
            }
            .accessibilityIdentifier(AccessibilityID.Tabs.settings)
        }
    }
}
