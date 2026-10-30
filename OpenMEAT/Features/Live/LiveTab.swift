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

/// Pick probes for a new cook. Each channel's role (meat / ambient), name and inclusion are
/// remembered for next time.
struct StartCookView: View {
    @Environment(AppModel.self) private var model
    @Environment(ChannelPreferences.self) private var channels
    @State private var devices: [DiscoveredDevice] = []
    @State private var title = ""
    @State private var error: String?
    @State private var isLoading = false
    @State private var renaming: CookProbe?
    @State private var renameText = ""

    /// Re-derived whenever preferences change, so pairing and colors stay correct.
    private var probes: [CookProbe] {
        ProbeDiscovery.probes(from: devices, customizations: channels.customizations)
    }

    var body: some View {
        let probes = probes
        List {
            Section("Cook") {
                TextField("Title (e.g. Brisket)", text: $title)
                    .accessibilityIdentifier(AccessibilityID.StartCook.title)
            }
            if probes.isEmpty {
                Section {
                    if isLoading {
                        ProgressView()
                    } else {
                        ContentUnavailableView("No probes found", systemImage: "thermometer.medium.slash",
                                               description: Text(error ?? "Make sure your RFX gateway is online."))
                    }
                }
            }
            let attention = devices.map(\.health).filter(\.battery.needsAttention)
            if !attention.isEmpty {
                Section {
                    BatteryWarning(devices: attention)
                }
            }
            // One section per device: batteries belong to devices (probes, gateway), not sensors —
            // ambient sensors wired into the gateway sit under the gateway.
            ForEach(sortedDevices) { discovered in
                let deviceProbes = probes.filter { $0.key.deviceSerial == discovered.device.serial }
                if !deviceProbes.isEmpty || discovered.device.isGateway {
                    Section {
                        ForEach(deviceProbes) { probe in
                            ProbeSetupRow(probe: probe, onRename: {
                                renameText = probe.label
                                renaming = probe
                            })
                        }
                        if deviceProbes.isEmpty {
                            Text("No sensors connected").font(.subheadline).foregroundStyle(.secondary)
                        }
                    } header: {
                        DeviceHeader(health: discovered.health)
                    }
                }
            }
            if !probes.isEmpty {
                Section {} footer: {
                    Text("Tap a sensor's role to switch between meat and ambient (pit). Names and roles are remembered for next time.")
                }
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
                    model.startCook(title: title, probes: probes.filter { channels.isIncluded($0.key) })
                }
                .bold()
                .disabled(!probes.contains { channels.isIncluded($0.key) })
                .accessibilityIdentifier(AccessibilityID.StartCook.start)
            }
        }
        .alert("Rename sensor", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let renaming { channels.setLabel(renameText, for: renaming.key) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    /// Wireless probes first, then the gateway.
    private var sortedDevices: [DiscoveredDevice] {
        devices.filter { !$0.device.isGateway } + devices.filter(\.device.isGateway)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            devices = try await model.discover()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ProbeSetupRow: View {
    @Environment(ChannelPreferences.self) private var channels
    let probe: CookProbe
    let onRename: () -> Void

    private var key: String { probe.key.description }

    var body: some View {
        HStack(spacing: 12) {
            ProbeSwatch(colorIndex: probe.colorIndex, role: probe.role)
            VStack(alignment: .leading, spacing: 4) {
                Button(action: onRename) {
                    HStack(spacing: 4) {
                        Text(probe.label).foregroundStyle(.primary)
                        Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.StartCook.rename(key))
                Picker("Role", selection: Binding(get: { probe.role }, set: { channels.setRole($0, for: probe.key) })) {
                    Label("Meat", systemImage: "thermometer.medium").tag(ProbeRole.internal)
                    Label("Ambient", systemImage: "flame").tag(ProbeRole.ambient)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityIdentifier(AccessibilityID.StartCook.role(key))
            }
            Spacer()
            Toggle("Include", isOn: Binding(get: { channels.isIncluded(probe.key) },
                                            set: { channels.setIncluded($0, for: probe.key) }))
                .labelsHidden()
                .accessibilityIdentifier(AccessibilityID.StartCook.probeToggle(key))
        }
        .padding(.vertical, 2)
    }
}

/// Solid dot for meat, ring for ambient — identity never relies on color alone.
struct ProbeSwatch: View {
    let colorIndex: Int
    let role: ProbeRole

    var body: some View {
        let color = ProbePalette.color(colorIndex, role: role)
        Group {
            if role == .ambient {
                Circle().strokeBorder(color, style: StrokeStyle(lineWidth: 2.5, dash: [3, 2]))
            } else {
                Circle().fill(color)
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}

private struct DeviceHeader: View {
    let health: DeviceHealth

    var body: some View {
        HStack {
            Label(health.label, systemImage: health.isGateway ? "wifi.router" : "thermometer.medium")
                .textCase(nil)
            Spacer()
            BatteryBadge(health: health)
                .textCase(nil)
        }
    }
}

/// Banner listing devices that need charging before a cook.
struct BatteryWarning: View {
    let devices: [DeviceHealth]

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(devices.count == 1 ? "Low battery" : "Low batteries").font(.subheadline.bold())
                Text(devices.map { d in "\(d.label)\(d.batteryPercent.map { " (\($0)%)" } ?? "")" }
                    .formatted(.list(type: .and)) + " — charge before a long cook.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            let critical = devices.contains { if case .critical = $0.battery { true } else { false } }
            Image(systemName: critical ? "battery.0percent" : "battery.25percent")
                .foregroundStyle(critical ? .red : .orange)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.StartCook.batteryWarning)
    }
}
