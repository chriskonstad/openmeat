import CookCore
import CookSession
import SwiftUI

struct LiveCookView: View {
    @Environment(AppModel.self) private var app
    @Environment(AppSettings.self) private var settings
    @Environment(ChannelPreferences.self) private var channels
    let cook: LiveCookModel
    @State private var targetProbe: CookProbe?
    @State private var confirmEnd = false
    @State private var renaming: CookProbe?
    @State private var renameText = ""

    private var snapshot: SessionSnapshot { cook.snapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                probeCards
                CookChartView(cook: snapshot.cook, estimates: snapshot.estimates, unit: settings.unit,
                              now: snapshot.now, isLive: true, staleChannels: snapshot.staleChannels,
                              wallClock: cook.wallClock)
                    .frame(height: 320)
                    .accessibilityIdentifier(AccessibilityID.Live.chart)
                NotesSection(cook: cook)
            }
            .padding()
        }
        .accessibilityIdentifier(AccessibilityID.Live.screen)
        .navigationTitle(snapshot.cook.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("End", role: .destructive) { confirmEnd = true }
                    .accessibilityIdentifier(AccessibilityID.Live.endCook)
            }
        }
        .alert("End this cook?", isPresented: $confirmEnd) {
            Button("Keep Cooking", role: .cancel) {}
                .accessibilityIdentifier(AccessibilityID.Live.cancelEnd)
            Button("End & Save", role: .destructive) {
                Task { await app.endCook(cook) }
            }
            .accessibilityIdentifier(AccessibilityID.Live.confirmEnd)
        } message: {
            Text("Recording stops after \(Formatting.duration(snapshot.cook.duration(asOf: snapshot.now))) and the cook is saved to History with its graph and notes.")
        }
        .alert("Rename sensor", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let renaming {
                    cook.setLabel(renameText, for: renaming.key)
                    channels.setLabel(renameText, for: renaming.key)
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .sheet(item: $targetProbe) { probe in
            TargetPickerView(probe: probe, unit: settings.unit) { target in
                cook.setTarget(target, for: probe.key)
            }
        }
        .refreshable { await cook.refreshNow() }
    }

    /// Long-press a card: rename or switch meat/ambient. Both are remembered for future cooks.
    @ViewBuilder
    private func sensorMenu(_ probe: CookProbe) -> some View {
        Button("Rename…", systemImage: "pencil") {
            renameText = probe.label
            renaming = probe
        }
        // A multi-sensor probe is always a meat probe; single sensors can be either.
        if snapshot.cook.sensors(of: probe.key).isEmpty {
            if probe.role == .ambient {
                Button("Use as meat probe", systemImage: "thermometer.medium") { setRole(.internal, probe) }
            } else {
                Button("Use as ambient (pit)", systemImage: "flame") { setRole(.ambient, probe) }
            }
        }
    }

    private func setRole(_ role: ProbeRole, _ probe: CookProbe) {
        cook.setRole(role, for: probe.key)
        channels.setRole(role, for: probe.key)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Started \(snapshot.cook.startedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.subheadline).foregroundStyle(.secondary)
                    // Ticks every second between polls (stopwatch style).
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(Formatting.clock(snapshot.cook.duration(asOf: cook.timeSource.now)))
                            .font(.title2.monospacedDigit().bold())
                            .contentTransition(.numericText())
                    }
                    .accessibilityIdentifier(AccessibilityID.Live.elapsed)
                }
                Spacer()
                if app.isDemo {
                    Text("DEMO").font(.caption.bold()).padding(6).background(.yellow.opacity(0.3), in: Capsule())
                }
            }
            FreshnessLabel(readingTime: snapshot.latestReadingTime,
                           readingWallClock: snapshot.latestReadingTime.map(cook.wallClock),
                           isStale: snapshot.isStale, error: snapshot.lastError)
            let attention = snapshot.devices.values.filter(\.battery.needsAttention).sorted { $0.label < $1.label }
            if !attention.isEmpty {
                BatteryWarning(devices: attention)
                    .accessibilityIdentifier(AccessibilityID.Live.batteryWarning)
            }
        }
    }

    private var probeCards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(snapshot.cook.probes.filter { $0.role == .internal || $0.role == .unknown }) { probe in
                    ProbeCardView(probe: probe, snapshot: snapshot, unit: settings.unit, timeSource: cook.timeSource,
                                  onTarget: { targetProbe = probe },
                                  onToggleSensors: {
                                      cook.setShowsSensors(!probe.showsSensors, for: probe.key)
                                      channels.setShowsSensors(!probe.showsSensors, for: probe.key)
                                  })
                    .contextMenu { sensorMenu(probe) }
                }
                ForEach(snapshot.cook.probes.filter { $0.role == .ambient }) { probe in
                    AmbientCardView(probe: probe, snapshot: snapshot, unit: settings.unit)
                        .contextMenu { sensorMenu(probe) }
                }
            }
        }
    }
}

struct ProbeCardView: View {
    let probe: CookProbe
    let snapshot: SessionSnapshot
    let unit: TemperatureUnit
    let timeSource: any TimeSource
    let onTarget: () -> Void
    var onToggleSensors: () -> Void = {}

    private var key: String { probe.key.description }
    private var latest: Sample? { snapshot.cook.latestSample(probe.key) }
    private var ambient: Sample? { probe.pairedAmbient.flatMap { snapshot.cook.latestSample($0) } }
    private var estimate: Estimate? { snapshot.estimates[probe.key] }
    private var isStale: Bool { snapshot.staleChannels.contains(probe.key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProbeSwatch(colorIndex: probe.colorIndex, role: probe.role)
                Text(probe.label).font(.headline).lineLimit(1)
                if let health = snapshot.devices[probe.key.deviceSerial] {
                    BatteryBadge(health: health, compact: true)
                }
                if isStale {
                    Image(systemName: "wifi.slash").foregroundStyle(.secondary).accessibilityLabel("No recent data")
                }
            }
            Text(latest.map { $0.temperature.formatted(unit, fractionDigits: 1) } ?? "--")
                .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(isStale ? .secondary : .primary)
                .accessibilityIdentifier(AccessibilityID.Live.probeTemp(key))
            if isStale, let latest {
                Text("as of \(latest.time.formatted(date: .omitted, time: .shortened))")
                    .font(.caption.weight(.semibold))
            }
            // Always takes its line (placeholder until the rate is known) so the layout doesn't jump.
            Text(Formatting.rate(snapshot.rates[probe.key] ?? estimate?.celsiusPerMinute, unit: unit) ?? "–°/min")
                .font(.caption).foregroundStyle(.secondary)
            Button(action: onTarget) {
                Label(probe.target.map { "Target \($0.formatted(unit))" } ?? "Set target", systemImage: "target")
                    .font(.subheadline.bold())
            }
            .buttonStyle(.bordered)
            .tint(ProbePalette.color(probe.colorIndex))
            .accessibilityIdentifier(AccessibilityID.Live.targetButton(key))
            // Ticks every second: time to target, then time since target once reached.
            let reachedAt = snapshot.cook.targetReachedAt(probe.key)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let now = timeSource.now
                Group {
                    if let reachedAt {
                        Label("Done · \(Formatting.clock(now.timeIntervalSince(reachedAt))) since target",
                              systemImage: "checkmark.circle.fill")
                    } else {
                        Text(Formatting.etaText(estimate, hasTarget: probe.target != nil, now: now))
                    }
                }
                .font(.subheadline.monospacedDigit())
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.Live.eta(key))
            let sensors = snapshot.cook.sensors(of: probe.key)
            if !sensors.isEmpty {
                Button(action: onToggleSensors) {
                    Label("All \(sensors.count) sensors", systemImage: probe.showsSensors ? "checkmark.square.fill" : "square")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.Live.showSensors(key))
                if probe.showsSensors {
                    SensorValues(sensors: sensors,
                                 values: Dictionary(uniqueKeysWithValues: sensors.compactMap { s in
                                     snapshot.cook.latestSample(s.key).map { (s.key, $0.temperature) } }),
                                 unit: unit)
                }
            }
            if let ambient {
                Label(ambient.temperature.formatted(unit), systemImage: "flame")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(minWidth: 220, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Live.probeCard(key))
    }
}

/// Compact card for an ambient (pit) sensor.
struct AmbientCardView: View {
    let probe: CookProbe
    let snapshot: SessionSnapshot
    let unit: TemperatureUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProbeSwatch(colorIndex: probe.colorIndex, role: probe.role)
                Text(probe.label).font(.subheadline).lineLimit(1)
            }
            Text(snapshot.cook.latestSample(probe.key).map { $0.temperature.formatted(unit) } ?? "--")
                .font(.title2.weight(.semibold).monospacedDigit())
            HStack(spacing: 4) {
                Text("Ambient")
                // Wired ambient sensors run off the gateway; show its battery.
                if let health = snapshot.devices[probe.key.deviceSerial], health.battery != .none {
                    Text("·")
                    Text(health.isGateway ? "Gateway" : health.label)
                    BatteryBadge(health: health, compact: true)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 130, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Live.probeCard(probe.key.description))
    }
}
