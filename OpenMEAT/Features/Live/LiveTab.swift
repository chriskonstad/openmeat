import CookCore
import CookSession
import SwiftUI

struct LiveTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            if let cook = model.activeCook {
                LiveCookView(cook: cook)
            } else {
                StartCookView()
            }
        }
    }
}

/// Pick probes for a new cook.
struct StartCookView: View {
    @Environment(AppModel.self) private var model
    @State private var devices: [DiscoveredDevice] = []
    @State private var probes: [CookProbe] = []
    @State private var selected: Set<ChannelKey> = []
    @State private var title = ""
    @State private var error: String?
    @State private var isLoading = false

    var body: some View {
        List {
            Section("Cook") {
                TextField("Title (e.g. Brisket)", text: $title)
                    .accessibilityIdentifier(AccessibilityID.StartCook.title)
            }
            Section {
                if isLoading && probes.isEmpty {
                    ProgressView()
                } else if probes.isEmpty {
                    ContentUnavailableView("No probes found", systemImage: "thermometer.medium.slash",
                                           description: Text(error ?? "Make sure your RFX gateway is online."))
                }
                ForEach(probes) { probe in
                    Toggle(isOn: binding(for: probe.key)) {
                        Label {
                            VStack(alignment: .leading) {
                                Text(probe.label)
                                Text(probe.role == .ambient ? "Ambient" : "Internal")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Circle().fill(ProbePalette.color(probe.colorIndex)).frame(width: 12, height: 12)
                        }
                    }
                    .accessibilityIdentifier(AccessibilityID.StartCook.probeToggle(probe.key.description))
                }
            } header: {
                Text("Probes")
            }
        }
        .navigationTitle("New cook")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
                    .accessibilityIdentifier(AccessibilityID.StartCook.refresh)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Start") {
                    model.startCook(title: title, probes: probes.filter { selected.contains($0.key) })
                }
                .bold()
                .disabled(selected.isEmpty)
                .accessibilityIdentifier(AccessibilityID.StartCook.start)
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func binding(for key: ChannelKey) -> Binding<Bool> {
        Binding(get: { selected.contains(key) },
                set: { isOn in if isOn { selected.insert(key) } else { selected.remove(key) } })
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            devices = try await model.discover()
            probes = ProbeDiscovery.probes(from: devices)
            selected = Set(probes.map(\.key))
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
