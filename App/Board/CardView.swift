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
    @State private var editingDue = false
    @State private var summarizing = false
    /// Whether the on-device model can handle this card's notes. Cached because answering it
    /// costs ~2ms (language detection over the whole body) and the menu is rebuilt with the
    /// card — a board of long cards would pay it on every layout pass.
    @State private var summarizable = false
    @FocusState private var notesFocused: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.body.weight(.semibold))
                    .onSubmit { commit() }
                    .accessibilityIdentifier("card.title")
                if summarizing {
                    ProgressView().controlSize(.mini)
                }
                Menu {
                    cardMenu
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(String(localized: "Card Actions"))
                .accessibilityIdentifier("card.actions")
            }

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
        .contextMenu { cardMenu }
        // Calendar's own shape for "pick an exact time": a popover, not a field wedged into
        // the card — the card face carries the date, never the picker.
        .popover(isPresented: $editingDue) {
            DatePicker("", selection: dueBinding, displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(12)
        }
        .onAppear { load() }
        // The same view instance is reused when a card moves column; reload so drafts follow it.
        .onChange(of: card.id) { _, _ in bodyDebouncer.cancel(); load() }
    }

    // MARK: - Menu

    /// One set of card actions, shown both from the ⋯ button and from a right-click — a card
    /// that only answers to the context menu hides half its features.
    @ViewBuilder
    private var cardMenu: some View {
        Menu("Due Date") {
            Button("Today") { setDue(Self.today()) }
            Button("Tomorrow") { setDue(Self.morning(daysFromNow: 1)) }
            Button("Next Week") { setDue(Self.morning(daysFromNow: 7)) }
            Button("Custom…") {
                if card.due == nil { setDue(Self.today()) }
                editingDue = true
            }
            if card.due != nil {
                Divider()
                Button("Remove Due Date") { update { $0.due = nil } }
            }
        }
        Button(expanded ? "Hide Notes" : "Show Notes") { expanded.toggle() }
        if summarizable {
            Button("Summarize into Title") { summarize() }
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

    // MARK: - Due date

    /// The card face states the date and opens the picker; it never carries the picker.
    @ViewBuilder
    private var dueRow: some View {
        if let due = card.due {
            Button {
                editingDue = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "calendar")
                    Text(due.formatted(date: .abbreviated, time: .shortened))
                        .strikethrough(isDone)
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(dueColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Change Due Date"))
        }
    }

    private var dueBinding: Binding<Date> {
        Binding(
            get: { card.due ?? Self.today() },
            set: { newValue in setDue(newValue) }
        )
    }

    /// Setting a date is the first moment a reminder can matter — and the only honest moment
    /// to ask for notification permission in an app that has no account and no onboarding.
    private func setDue(_ date: Date) {
        update { $0.due = date }
        Task { await DueNotifier.shared.requestAuthorizationIfNeeded() }
    }

    /// Today at 17:00, or the next full hour if that has already passed.
    private static func today() -> Date {
        let calendar = Calendar.current
        let end = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: Date())
        if let end, end > Date() { return end }
        let next = calendar.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        return calendar.date(bySetting: .minute, value: 0, of: next) ?? next
    }

    private static func morning(daysFromNow days: Int) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: days, to: Date()) ?? Date()
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
    }

    // MARK: - Summary

    /// Replaces the title with a short on-device summary of the notes. The notes are never
    /// touched: a summary that reads badly costs one undo-by-retyping, not the text.
    private func summarize() {
        let source = body_
        summarizing = true
        Task {
            let summary = await CardSummarizer.title(for: source)
            summarizing = false
            guard let summary, !summary.isEmpty else { return }
            title = summary
            commit()
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
            .accessibilityIdentifier("card.notesToggle")

            if expanded {
                // axis: .vertical grows with its content instead of reserving a fixed block,
                // and unlike TextEditor it takes the caret on a single click. No upper line
                // limit: a capped field clips the rest of the text AND eats the scroll wheel,
                // so the column underneath can't be scrolled while the pointer is over it.
                TextField("Notes", text: $body_, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .lineLimit(1...)
                    .focused($notesFocused)
                    .newlineOnModifiedReturn()
                    .accessibilityIdentifier("card.notes")
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
        refreshSummarizable()
    }

    /// Off the main thread: this is a menu's enabled-state, never worth a frame.
    private func refreshSummarizable() {
        let source = body_
        Task {
            let available = await Task.detached { CardSummarizer.canSummarize(source) }.value
            summarizable = available
        }
    }

    private func commit() {
        update {
            // An empty title would be rejected by the store; keep the stored one instead.
            $0.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? card.title : title
            $0.body = body_.isEmpty ? nil : body_
        }
        refreshSummarizable()
    }

    private func update(_ change: (inout Card) -> Void) {
        var updated = card
        change(&updated)
        try? store.updateCard(boardID: boardID, card: updated)
    }
}
