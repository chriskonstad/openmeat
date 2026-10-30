import CookCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section("Display") {
                    Picker("Units", selection: $settings.unit) {
                        Text("°F").tag(TemperatureUnit.fahrenheit)
                        Text("°C").tag(TemperatureUnit.celsius)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier(AccessibilityID.Settings.unit)
                }
                Section {
                    Stepper(value: $settings.almostDoneLeadMinutes, in: AppSettings.leadMinutesRange) {
                        LabeledContent("Almost-done alert", value: "\(settings.almostDoneLeadMinutes) min before")
                            .accessibilityIdentifier(AccessibilityID.Settings.leadTimeValue)
                    }
                    .accessibilityIdentifier(AccessibilityID.Settings.leadTime)
                    Toggle("Live Activity", isOn: $settings.liveActivitiesEnabled)
                        .accessibilityIdentifier(AccessibilityID.Settings.liveActivities)
                } header: {
                    Text("Alerts")
                } footer: {
                    Text("Alerts are based on the estimated time to target and may fire early or late.")
                }
                Section("Data") {
                    Picker("Refresh every", selection: $settings.pollIntervalSeconds) {
                        ForEach([5.0, 10, 15, 30, 60], id: \.self) { Text("\(Int($0)) s").tag($0) }
                    }
                }
                Section {
                    if model.isDemo {
                        LabeledContent("Mode", value: "Demo (simulated)")
                    }
                    Button(model.isDemo ? "Exit demo" : "Sign out", role: .destructive) {
                        Task { await model.signOut() }
                    }
                    .accessibilityIdentifier(AccessibilityID.Settings.signOut)
                }
                Section {} footer: {
                    Text("OpenMEAT \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") · Not affiliated with ThermoWorks.")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
