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

/// Pick probes for a new cook. Mirrors the hardware: the gateway (status, battery, wired sensors),
/// then each wireless probe as one row (core temp, battery, connection, optional per-sensor view).
/// Choices are remembered per channel.
struct StartCookView: View {
    @Environment(AppModel.self) private var model
    @Environment(ChannelPreferences.self) private var channels
    @State private var devices: [DiscoveredDevice] = []
    /// When `devices` was fetched; connection status is judged against this, not the current time,
    /// so a list left open doesn't decay into "offline". The list refreshes every 30 s.
    @State private var fetchedAt: Date?
    @State private var title = ""
    @State private var error: String?
    @State private var isLoading = false
    @State private var renaming: CookProbe?
    @State private var renameText = ""

    /// Re-derived whenever preferences change, so pairing and colors stay correct.
    private var probes: [CookProbe] {
        ProbeDiscovery.probes(from: devices, customizations: channels.customizations)
    }

    private var now: Date { fetchedAt ?? model.timeSource.now }

    private func health(_ serial: String) -> DeviceHealth? {
        devices.first { $0.device.serial == serial }?.health
    }

    /// Offline devices default to excluded until the user decides.
    private func isIncluded(_ probe: CookProbe) -> Bool {
        let online = health(probe.key.deviceSerial).map { $0.connection(now: now) == .online } ?? true
        return channels.isIncluded(probe.key, default: online)
    }

    /// Sensors follow their probe.
    private var selectedProbes: [CookProbe] {
        let all = probes
        let included = Set(all.filter { $0.role != .sensor && isIncluded($0) }.map(\.key))
        return all.filter { included.contains($0.parent ?? $0.key) }
    }

    var body: some View {
        let probes = probes
        let gateways = devices.filter(\.device.isGateway)
        let others = devices.filter { !$0.device.isGateway }
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
                Section { BatteryWarning(devices: attention) }
            }
            ForEach(gateways) { gateway in
                Section {
                    DeviceStatusRow(health: gateway.health, now: now)
                    ForEach(probes.filter { $0.key.deviceSerial == gateway.device.serial }) { probe in
                        ProbeSetupRow(probe: probe, value: value(of: probe), onRename: { rename(probe) })
                    }
                } header: {
                    Text("Gateway")
                } footer: {
                    Text("Sensors plugged into the gateway are wired, so they share its power.")
                }
            }
            if !others.isEmpty {
                Section {
                    ForEach(others) { device in
                        let deviceProbes = probes.filter { $0.key.deviceSerial == device.device.serial }
                        if let core = deviceProbes.first(where: { p in p.role == .internal && deviceProbes.contains { $0.parent == p.key } }) {
                            WirelessProbeRow(core: core, sensors: deviceProbes.filter { $0.parent == core.key },
                                             health: device.health, now: now,
                                             values: device.channels.reduce(into: [:]) { $0[$1.key] = $1.temperature },
                                             isIncluded: isIncluded(core),
                                             onRename: { rename(core) })
                        } else {
                            // Other hardware: one row per channel.
                            DeviceStatusRow(health: device.health, now: now)
                            ForEach(deviceProbes) { probe in
                                ProbeSetupRow(probe: probe, value: value(of: probe), onRename: { rename(probe) })
                            }
                        }
                    }
                } header: {
                    Text("Probes")
                } footer: {
                    Text("A probe's temperature is its core: the coldest of its sensors. Names, roles and choices are remembered for next time.")
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
                    model.startCook(title: title, probes: selectedProbes)
                }
                .bold()
                .disabled(!selectedProbes.contains { $0.role != .sensor })
                .accessibilityIdentifier(AccessibilityID.StartCook.start)
            }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let renaming { channels.setLabel(renameText, for: renaming.key) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .refreshable { await load() }
    }

    private func rename(_ probe: CookProbe) {
        renameText = probe.label
        renaming = probe
    }

    private func value(of probe: CookProbe) -> Temperature? {
        devices.first { $0.device.serial == probe.key.deviceSerial }?
            .channels.first { $0.key == probe.key }?.temperature
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await model.discover()
            devices = fetched
            fetchedAt = model.timeSource.now
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Gateway or generic device: name, connection, signal, battery.
private struct DeviceStatusRow: View {
    let health: DeviceHealth
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(health.label, systemImage: health.isGateway ? "wifi.router" : "thermometer.medium")
                    .font(.body.weight(.semibold))
                Spacer()
                BatteryBadge(health: health)
            }
            ConnectionLabel(health: health, now: now)
                .accessibilityIdentifier(AccessibilityID.StartCook.connection(health.serial))
        }
    }
}

/// One wireless multi-sensor probe (RFX MEAT): include checkbox, name, battery, connection,
/// core temp, and an optional per-sensor view.
private struct WirelessProbeRow: View {
    @Environment(ChannelPreferences.self) private var channels
    @Environment(AppSettings.self) private var settings
    let core: CookProbe
    let sensors: [CookProbe]
    let health: DeviceHealth
    let now: Date
    let values: [ChannelKey: Temperature]
    let isIncluded: Bool
    let onRename: () -> Void

    private var key: String { core.key.description }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    channels.setIncluded(!isIncluded, for: core.key)
                } label: {
                    Image(systemName: isIncluded ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(isIncluded ? ProbePalette.color(core.colorIndex) : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isIncluded ? "Included" : "Not included")
                .accessibilityIdentifier(AccessibilityID.StartCook.probeToggle(key))
                Button(action: onRename) {
                    HStack(spacing: 4) {
                        Text(core.label).font(.body.weight(.semibold)).foregroundStyle(.primary)
                        Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.StartCook.rename(key))
                Spacer()
                BatteryBadge(health: health)
            }
            HStack {
                ConnectionLabel(health: health, now: now)
                    .accessibilityIdentifier(AccessibilityID.StartCook.connection(health.serial))
                Spacer()
                if let core = values[core.key] {
                    Text("Core \(core.formatted(settings.unit, fractionDigits: 1))")
                        .font(.subheadline.monospacedDigit())
                }
            }
            if !sensors.isEmpty {
                Button {
                    channels.setShowsSensors(!core.showsSensors, for: core.key)
                } label: {
                    Label("Show all \(sensors.count) sensors", systemImage: core.showsSensors ? "checkmark.square.fill" : "square")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.StartCook.showSensors(key))
                if core.showsSensors {
                    SensorValues(sensors: sensors, values: values, unit: settings.unit)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Compact list of a probe's sensor readings ("1 87.5°  2 86.9° …"), coldest highlighted.
struct SensorValues: View {
    let sensors: [CookProbe]
    let values: [ChannelKey: Temperature]
    let unit: TemperatureUnit

    var body: some View {
        let coldest = sensors.compactMap { values[$0.key] }.min()
        HStack(spacing: 12) {
            ForEach(sensors) { sensor in
                let value = values[sensor.key]
                VStack(spacing: 1) {
                    Text(sensor.label.replacingOccurrences(of: "Sensor ", with: "#")).font(.caption2).foregroundStyle(.secondary)
                    Text(value.map { $0.formatted(unit, symbol: false) + "°" } ?? "--")
                        .font(.subheadline.monospacedDigit().weight(value == coldest ? .bold : .regular))
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// "● Online · ▂▄▆" or "○ Last seen 14 hr ago".
struct ConnectionLabel: View {
    let health: DeviceHealth
    let now: Date

    var body: some View {
        HStack(spacing: 6) {
            switch health.connection(now: now) {
            case .online:
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("Online")
                if let signal = health.signal {
                    Image(systemName: health.isGateway ? "wifi" : "cellularbars",
                          variableValue: Double(signal.rawValue) / 3)
                    Text(signal == .strong ? "Strong" : signal == .fair ? "Fair" : "Weak")
                }
            case .offline(let lastSeen):
                Circle().strokeBorder(.secondary, lineWidth: 1.5).frame(width: 8, height: 8)
                if let lastSeen {
                    Text("Last seen \(lastSeen.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))")
                } else {
                    Text("Offline")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

private struct ProbeSetupRow: View {
    @Environment(ChannelPreferences.self) private var channels
    @Environment(AppSettings.self) private var settings
    let probe: CookProbe
    var value: Temperature?
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
            if let value {
                Text(value.formatted(settings.unit, fractionDigits: 1))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
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
                Text(devices.count == 1 ? "Battery almost empty" : "Batteries almost empty").font(.subheadline.bold())
                Text(devices.map { d in "\(d.label)\(d.batteryPercent.map { " (\($0)%)" } ?? "")" }
                    .formatted(.list(type: .and)) + " — charge before a long cook.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "battery.0percent").foregroundStyle(.red)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.StartCook.batteryWarning)
    }
}
