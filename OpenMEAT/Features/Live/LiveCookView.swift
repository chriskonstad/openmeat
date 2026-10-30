import CookCore
import CookSession
import SwiftUI

struct LiveCookView: View {
    @Environment(AppModel.self) private var app
    @Environment(AppSettings.self) private var settings
    let cook: LiveCookModel
    @State private var targetProbe: CookProbe?
    @State private var confirmEnd = false

    private var snapshot: SessionSnapshot { cook.snapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                probeCards
                CookChartView(cook: snapshot.cook, estimates: snapshot.estimates, unit: settings.unit,
                              now: snapshot.now, isLive: true)
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
        .confirmationDialog("End this cook?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End cook", role: .destructive) {
                Task { await app.endCook(cook) }
            }
            .accessibilityIdentifier(AccessibilityID.Live.confirmEnd)
        }
        .sheet(item: $targetProbe) { probe in
            TargetPickerView(probe: probe, unit: settings.unit) { target in
                cook.setTarget(target, for: probe.key)
            }
        }
        .refreshable { await cook.refreshNow() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Started \(snapshot.cook.startedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(Formatting.duration(snapshot.cook.duration(asOf: snapshot.now)))
                    .font(.title2.monospacedDigit().bold())
                    .accessibilityIdentifier(AccessibilityID.Live.elapsed)
            }
            Spacer()
            if let error = snapshot.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).lineLimit(2)
            } else if app.isDemo {
                Text("DEMO").font(.caption.bold()).padding(6).background(.yellow.opacity(0.3), in: Capsule())
            }
        }
    }

    private var probeCards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(snapshot.cook.probes.filter { $0.role != .ambient }) { probe in
                    ProbeCardView(probe: probe, snapshot: snapshot, unit: settings.unit) {
                        targetProbe = probe
                    }
                }
            }
        }
    }
}

struct ProbeCardView: View {
    let probe: CookProbe
    let snapshot: SessionSnapshot
    let unit: TemperatureUnit
    let onTarget: () -> Void

    private var key: String { probe.key.description }
    private var latest: Sample? { snapshot.cook.latestSample(probe.key) }
    private var ambient: Sample? { probe.pairedAmbient.flatMap { snapshot.cook.latestSample($0) } }
    private var estimate: Estimate? { snapshot.estimates[probe.key] }
    private var isStale: Bool { snapshot.staleChannels.contains(probe.key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(ProbePalette.color(probe.colorIndex)).frame(width: 10, height: 10)
                Text(probe.label).font(.headline).lineLimit(1)
                if isStale {
                    Image(systemName: "wifi.slash").foregroundStyle(.orange).accessibilityLabel("No recent data")
                }
            }
            Text(latest.map { $0.temperature.formatted(unit, fractionDigits: 1) } ?? "--")
                .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                .accessibilityIdentifier(AccessibilityID.Live.probeTemp(key))
            if let rate = Formatting.rate(estimate?.celsiusPerMinute, unit: unit) {
                Text(rate).font(.caption).foregroundStyle(.secondary)
            }
            Button(action: onTarget) {
                Label(probe.target.map { "Target \($0.formatted(unit))" } ?? "Set target", systemImage: "target")
                    .font(.subheadline.bold())
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(AccessibilityID.Live.targetButton(key))
            Text(Formatting.etaText(estimate, hasTarget: probe.target != nil, now: snapshot.now))
                .font(.subheadline.monospacedDigit())
                .accessibilityIdentifier(AccessibilityID.Live.eta(key))
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
