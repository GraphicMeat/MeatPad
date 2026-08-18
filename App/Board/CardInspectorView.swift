import SwiftUI
import MeatPadKit

/// Trailing detail pane for the selected card: title, body, due date, delete. Edits write
/// through `BoardStore.updateCard` — the title on submit, the body debounced, so typing a
/// paragraph isn't one disk write per keystroke.
struct CardInspectorView: View {
    @ObservedObject var store: BoardStore
    let boardID: UUID
    let card: Card
    var onDelete: () -> Void

    @State private var title = ""
    @State private var body_ = ""
    @State private var due: Date = Date()
    @State private var hasDue = false
    @State private var bodyDebouncer = Debouncer(delay: 0.5)
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(.title3.weight(.medium))
                .onSubmit { commit() }
                .accessibilityIdentifier("card.title")

            Divider().opacity(0.4)

            Text("Notes").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $body_)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 120)
                .onChange(of: body_) { _, _ in bodyDebouncer.call { commit() } }
                .accessibilityIdentifier("card.body")

            Toggle("Due Date", isOn: $hasDue)
                .onChange(of: hasDue) { _, isOn in
                    commit()
                    // Only ever prompted here — the first time a card actually gets a date.
                    if isOn { Task { await DueNotifier.shared.requestAuthorizationIfNeeded() } }
                }
            if hasDue {
                DatePicker("", selection: $due, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .onChange(of: due) { _, _ in commit() }
            }

            linkedNote

            Spacer()

            Button(role: .destructive) {
                bodyDebouncer.cancel()
                try? store.deleteCard(boardID: boardID, cardID: card.id)
                onDelete()
            } label: {
                Label("Delete Card", systemImage: "trash")
            }
            .accessibilityIdentifier("card.delete")
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { load() }
        // Switching cards must not carry the previous card's drafts across.
        .onChange(of: card.id) { _, _ in bodyDebouncer.cancel(); load() }
    }

    /// The note side of the link, resolved live. A trashed or deleted note keeps the link
    /// and reads as unavailable — restoring the note makes it whole again.
    @ViewBuilder
    private var linkedNote: some View {
        if let noteID = card.noteID {
            Divider().opacity(0.4)
            HStack(spacing: 6) {
                Image(systemName: "link").foregroundStyle(.secondary)
                if let note = AppModel.shared.noteStore.notes.first(where: { $0.id == noteID }) {
                    Button(note.title) { openWindow(value: noteID) }
                        .buttonStyle(.link)
                        .lineLimit(1)
                        .help(String(localized: "Open Note"))
                } else {
                    Text("Note unavailable").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Unlink") {
                    var updated = card
                    updated.noteID = nil
                    try? store.updateCard(boardID: boardID, card: updated)
                }
                .buttonStyle(.borderless)
            }
            .font(.callout)
        }
    }

    private func load() {
        title = card.title
        body_ = card.body ?? ""
        hasDue = card.due != nil
        due = card.due ?? Date().addingTimeInterval(3600)
    }

    private func commit() {
        var updated = card
        // An empty title would be rejected by the store; keep the stored one instead.
        updated.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? card.title : title
        updated.body = body_.isEmpty ? nil : body_
        updated.due = hasDue ? due : nil
        try? store.updateCard(boardID: boardID, card: updated)
    }
}
