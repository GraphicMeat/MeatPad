import SwiftUI
import MeatPadKit

/// One card, editable in place: the board is the editor, so there is no inspector pane.
/// Title and due date are always visible; the notes body folds away and remembers its state
/// for as long as the board is on screen.
struct CardView: View {
    @ObservedObject var store: BoardStore
    let boardID: UUID
    let card: Card
    /// Board name badge, shown only in the All Boards overview.
    var boardBadge: String?
    let isDone: Bool
    let isSelected: Bool

    @State private var title = ""
    @State private var body_ = ""
    @State private var expanded = false
    @State private var duePickerShown = false
    @State private var due = Date()
    @State private var bodyDebouncer = Debouncer(delay: 0.5)
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(.body.weight(.medium))
                .onSubmit { commit() }

            HStack(spacing: 8) {
                dueControl
                if card.noteID != nil { linkChip }
                Spacer()
                if let boardBadge {
                    Text(boardBadge)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.quaternary))
                }
            }

            DisclosureGroup(isExpanded: $expanded) {
                TextEditor(text: $body_)
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 64)
                    .onChange(of: body_) { _, _ in bodyDebouncer.call { commit() } }
            } label: {
                Text("Notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.thinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(isSelected ? AnyShapeStyle(MeatPadGlass.tint) : AnyShapeStyle(.white.opacity(0.12)), lineWidth: 1)
                }
        }
        .contextMenu {
            Button(expanded ? "Hide Notes" : "Show Notes") { expanded.toggle() }
            if card.noteID != nil {
                Button("Unlink") { update { $0.noteID = nil } }
            }
            Divider()
            Button("Delete Card", role: .destructive) {
                bodyDebouncer.cancel()
                try? store.deleteCard(boardID: boardID, cardID: card.id)
            }
        }
        .onAppear { load() }
        // Same view instance is reused when a card moves column; reload so drafts follow it.
        .onChange(of: card.id) { _, _ in bodyDebouncer.cancel(); load() }
    }

    // MARK: - Due date

    @ViewBuilder
    private var dueControl: some View {
        Button {
            due = card.due ?? Date().addingTimeInterval(3600)
            duePickerShown = true
        } label: {
            Label {
                Text(card.due.map { $0.formatted(.dateTime.month().day().hour().minute()) } ?? String(localized: "Add Due Date"))
            } icon: {
                Image(systemName: "calendar")
            }
            .font(.caption2)
            .foregroundStyle(dueColor)
            .strikethrough(isDone && card.due != nil)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $duePickerShown) {
            VStack(alignment: .leading, spacing: 10) {
                DatePicker("Due Date", selection: $due, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                HStack {
                    Button("Set") {
                        update { $0.due = due }
                        // Only ever prompted here — the first time a card actually gets a date.
                        Task { await DueNotifier.shared.requestAuthorizationIfNeeded() }
                        duePickerShown = false
                    }
                    if card.due != nil {
                        Button("Clear") {
                            update { $0.due = nil }
                            duePickerShown = false
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    /// Overdue reads red, due today orange, everything else secondary — and a finished card
    /// is never "late".
    private var dueColor: Color {
        guard let due = card.due, !isDone else { return .secondary }
        if due < Date() { return .red }
        if Calendar.current.isDateInToday(due) { return .orange }
        return .secondary
    }

    // MARK: - Linked note

    private var linkChip: some View {
        Button {
            if let noteID = card.noteID { openWindow(value: noteID) }
        } label: {
            Label {
                Text(linkedTitle).lineLimit(1)
            } icon: {
                Image(systemName: "link")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(String(localized: "Open Note"))
    }

    /// Resolved live: a trashed or deleted note reads as unavailable and the link is kept,
    /// so restoring the note makes it whole again.
    private var linkedTitle: String {
        guard let noteID = card.noteID,
              let note = AppModel.shared.noteStore.notes.first(where: { $0.id == noteID })
        else { return String(localized: "Note unavailable") }
        return note.title
    }

    // MARK: - Editing

    private func load() {
        title = card.title
        body_ = card.body ?? ""
        // Cards open folded unless they carry notes worth reading.
        expanded = !(card.body ?? "").isEmpty
    }

    private func commit() {
        update {
            // An empty title would be rejected by the store; keep the stored one instead.
            $0.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? card.title : title
            $0.body = body_.isEmpty ? nil : body_
        }
    }

    private func update(_ change: (inout Card) -> Void) {
        var updated = card
        change(&updated)
        try? store.updateCard(boardID: boardID, card: updated)
    }
}
