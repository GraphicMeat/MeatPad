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
                .onChange(of: hasDue) { _, _ in commit() }
            if hasDue {
                DatePicker("", selection: $due, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .onChange(of: due) { _, _ in commit() }
            }

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
