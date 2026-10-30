import SwiftUI

@main
struct OpenMEATApp: App {
    @State private var model = AppModel()

    init() {
        if LaunchConfiguration.current.disableAnimations {
            UIView.setAnimationsEnabled(false)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.settings)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .signedOut, .signingIn:
            LoginView()
        case .ready:
            MainTabView()
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
