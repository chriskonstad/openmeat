import CookCore
import SwiftUI

/// Quick-note chips, free-text composer, and the cook's note list.
struct NotesSection: View {
    @Environment(AppSettings.self) private var settings
    let cook: LiveCookModel
    @State private var draft = ""
    @State private var isComposing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Notes").font(.headline)
                Spacer()
                Button("Add note", systemImage: "square.and.pencil") { isComposing = true }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier(AccessibilityID.Notes.addButton)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(settings.quickNotes, id: \.self) { text in
                        Button(text) { cook.addNote(text, isQuickNote: true) }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier(AccessibilityID.Notes.quick(text))
                    }
                }
            }
            NoteList(notes: cook.cook.notes, startedAt: cook.cook.startedAt, onDelete: cook.deleteNote)
        }
        .alert("Add note", isPresented: $isComposing) {
            TextField("What happened?", text: $draft)
                .accessibilityIdentifier(AccessibilityID.Notes.field)
            Button("Save") {
                cook.addNote(draft)
                draft = ""
            }
            .accessibilityIdentifier(AccessibilityID.Notes.save)
            Button("Cancel", role: .cancel) { draft = "" }
        }
    }
}

struct NoteList: View {
    let notes: [CookNote]
    let startedAt: Date
    var onDelete: ((UUID) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if notes.isEmpty {
                Text("No notes yet").foregroundStyle(.secondary).font(.subheadline)
            }
            ForEach(notes.reversed()) { note in
                HStack(alignment: .firstTextBaseline) {
                    Text(note.time.formatted(date: .omitted, time: .shortened))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text("+" + Formatting.duration(note.time.timeIntervalSince(startedAt)))
                        .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    Text(note.text)
                    Spacer()
                }
                .contextMenu {
                    if let onDelete {
                        Button("Delete", systemImage: "trash", role: .destructive) { onDelete(note.id) }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Notes.list)
    }
}
