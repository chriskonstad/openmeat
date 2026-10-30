import CookCore
import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @State private var summaries: [CookSummary] = []

    var body: some View {
        NavigationStack {
            Group {
                if summaries.isEmpty {
                    ContentUnavailableView("No cooks yet", systemImage: "flame",
                                           description: Text("Finished cooks show up here."))
                        .accessibilityIdentifier(AccessibilityID.History.empty)
                } else {
                    List {
                        ForEach(summaries) { summary in
                            NavigationLink(value: summary.id) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(summary.title).font(.headline)
                                    HStack {
                                        Text(summary.startedAt.formatted(date: .abbreviated, time: .shortened))
                                        if let end = summary.endedAt {
                                            Text("· \(Formatting.duration(end.timeIntervalSince(summary.startedAt)))")
                                        }
                                        if let peak = summary.peakCelsius {
                                            Text("· peak \(Temperature(celsius: peak).formatted(settings.unit))")
                                        }
                                    }
                                    .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityIdentifier(AccessibilityID.History.row(summary.title))
                        }
                        .onDelete { offsets in
                            let ids = offsets.map { summaries[$0].id }
                            Task {
                                for id in ids { try? await model.store.delete(id: id) }
                                await reload()
                            }
                        }
                    }
                    .accessibilityIdentifier(AccessibilityID.History.list)
                }
            }
            .navigationTitle("History")
            .navigationDestination(for: UUID.self) { id in
                CookDetailView(id: id)
            }
            .task(id: model.activeCook == nil) { await reload() }
            .refreshable { await reload() }
        }
    }

    private func reload() async {
        // The active cook is persisted too; only list finished cooks.
        summaries = ((try? await model.store.summaries()) ?? []).filter { $0.endedAt != nil }
    }
}

struct CookDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    let id: UUID
    @State private var cook: Cook?

    var body: some View {
        ScrollView {
            if let cook {
                VStack(alignment: .leading, spacing: 16) {
                    Text("\(cook.startedAt.formatted(date: .long, time: .shortened)) · \(Formatting.duration(cook.duration(asOf: cook.startedAt)))")
                        .foregroundStyle(.secondary)
                    CookChartView(cook: cook, estimates: [:], unit: settings.unit, now: cook.endedAt ?? cook.startedAt, isLive: false)
                        .frame(height: 320)
                        .accessibilityIdentifier(AccessibilityID.History.detailChart)
                    Text("Notes").font(.headline)
                    NoteList(notes: cook.notes, startedAt: cook.startedAt)
                }
                .padding()
            } else {
                ProgressView()
            }
        }
        .navigationTitle(cook?.title ?? "")
        .toolbar {
            if let cook {
                ShareLink(item: CookExporter.csv(cook, unit: settings.unit),
                          preview: SharePreview("\(cook.title).csv")) {
                    Label("Export CSV", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier(AccessibilityID.History.export)
            }
        }
        .task { cook = try? await model.store.load(id: id) }
    }
}
