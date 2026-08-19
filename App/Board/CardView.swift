import SwiftUI
import MeatPadKit

/// One card, editable in place — the board is the editor, so nothing opens a pane or a
/// popup. Height follows content: a bare card is two lines tall, and the notes field grows
/// only as far as the text it holds.
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
    @State private var bodyDebouncer = Debouncer(delay: 0.5)
    @FocusState private var notesFocused: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(.body.weight(.semibold))
                .onSubmit { commit() }

            dueRow

            if card.noteID != nil || boardBadge != nil {
                HStack(spacing: 6) {
                    if card.noteID != nil { linkChip }
                    Spacer(minLength: 0)
                    if let boardBadge {
                        Text(boardBadge)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.quaternary))
                    }
                }
            }

            notesSection
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.thinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            isSelected ? AnyShapeStyle(MeatPadGlass.violet.opacity(0.9)) : AnyShapeStyle(.white.opacity(0.10)),
                            lineWidth: isSelected ? 1.5 : 1
                        )
                }
                .shadow(color: .black.opacity(isSelected ? 0.28 : 0.16), radius: isSelected ? 7 : 3, y: 2)
        }
        .contextMenu {
            Button(expanded ? "Hide Notes" : "Show Notes") { expanded.toggle() }
            if card.due != nil {
                Button("Remove Due Date") { update { $0.due = nil } }
            }
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
        // The same view instance is reused when a card moves column; reload so drafts follow it.
        .onChange(of: card.id) { _, _ in bodyDebouncer.cancel(); load() }
    }

    // MARK: - Due date

    /// Calendar's event fields, not a popup: an editable date/time field that commits as you
    /// type, plus one button to take the date off again.
    @ViewBuilder
    private var dueRow: some View {
        if card.due != nil {
            HStack(spacing: 5) {
                Image(systemName: "calendar")
                    .font(.caption)
                    .foregroundStyle(dueColor)
                DatePicker("", selection: dueBinding, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.field)
                    .labelsHidden()
                    .font(.caption)
                    .fixedSize()
                Button {
                    update { $0.due = nil }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help(String(localized: "Remove Due Date"))
                Spacer(minLength: 0)
            }
            .foregroundStyle(dueColor)
        } else {
            Button {
                update { $0.due = Self.defaultDue() }
            } label: {
                Label("Add Due Date", systemImage: "calendar.badge.plus")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private var dueBinding: Binding<Date> {
        Binding(
            get: { card.due ?? Self.defaultDue() },
            set: { newValue in update { $0.due = newValue } }
        )
    }

    /// Next full hour — the same "sensible default" Calendar picks for a new event.
    private static func defaultDue() -> Date {
        let calendar = Calendar.current
        let next = calendar.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        return calendar.date(bySetting: .minute, value: 0, of: next) ?? next
    }

    /// Overdue reads red, due today orange, everything else secondary — and a finished card
    /// is never "late".
    private var dueColor: Color {
        guard let due = card.due, !isDone else { return .secondary }
        if due < Date() { return .red }
        if Calendar.current.isDateInToday(due) { return .orange }
        return .secondary
    }

    // MARK: - Notes

    /// Collapsed shows one line of what's there (nothing at all if the card has no notes);
    /// clicking anywhere on the row opens the field AND puts the caret in it.
    @ViewBuilder
    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expanded.toggle()
                if expanded { notesFocused = true }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    if expanded || body_.isEmpty {
                        Text("Notes")
                    } else {
                        Text(body_).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                // axis: .vertical grows with its content instead of reserving a fixed block,
                // and unlike TextEditor it takes the caret on a single click.
                TextField("Notes", text: $body_, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .lineLimit(1...12)
                    .focused($notesFocused)
                    .onChange(of: body_) { _, _ in bodyDebouncer.call { commit() } }
            }
        }
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

    /// Resolved live: a trashed or deleted note reads as unavailable and the link is kept, so
    /// restoring the note makes it whole again.
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
