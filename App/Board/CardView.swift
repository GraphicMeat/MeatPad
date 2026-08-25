import SwiftUI
import MeatPadKit

/// One card, editable in place — the board is the editor, so the common edits (title,
/// notes, due date) never cost a click. Height follows content: a bare card is two lines
/// tall, the title wraps rather than truncates, and the notes field grows only as far as
/// the text it holds. `⋯` opens `CardEditor` for everything at once.
struct CardView: View {
    @ObservedObject var store: BoardStore
    let boardID: UUID
    let card: Card
    /// Board name badge, shown only in the All Boards overview. Carries the board's own
    /// colour with it — in a view that stacks four boards into one column, the badge is the
    /// only thing saying which board a card came from, and four grey badges say it slowly.
    var boardBadge: (name: String, color: RGBAColor)?
    let isDone: Bool
    let isSelected: Bool
    /// How much of the card to draw. Owned by the board, not the card — "fold everything"
    /// is a board-wide gesture — but a card can still open its own notes from the ⋯ menu
    /// until the setting next changes.
    let display: CardDisplay

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
    @State private var editorShown = false
    /// Whether the editor should open straight onto its new-label field.
    @State private var editorLabelForm = false
    @FocusState private var notesFocused: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 6) {
                // axis: .vertical so a long title wraps onto as many lines as it needs, up to
                // what the board's display setting allows. A card that reads "Masazas E…" is a
                // card you have to open to identify — which is why only `compact` clips it.
                // No `newlineOnModifiedReturn` here on purpose: wrapping is layout, and a
                // title with a literal newline in it is a title nothing can render.
                TextField("Title", text: $title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body.weight(.semibold))
                    .lineLimit(display.titleLines)
                    .onSubmit { commit() }
                    // A vertical-axis TextField that has already grown does not shrink back
                    // when the limit tightens — it keeps the taller intrinsic size. Rebuilding
                    // it on the limit itself is the cheapest way to re-measure, and titles↔full
                    // share a limit, so it only happens on the switch that changes anything.
                    .id(display.titleLines)
                    .accessibilityIdentifier("card.title")
                if summarizing {
                    ProgressView().controlSize(.mini)
                }
                Button {
                    editorLabelForm = false
                    editorShown = true
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                        // A bare glyph is a 13pt target sitting next to a card that answers
                        // clicks itself — miss it and you select the card instead.
                        .frame(width: 22, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Card Actions"))
                .accessibilityIdentifier("card.actions")
            }
            // Anchored to the header row so it points at the ⋯ it came from.
            .popover(isPresented: $editorShown, arrowEdge: .bottom) {
                CardEditor(
                    store: store,
                    boardID: boardID,
                    card: card,
                    isPresented: $editorShown,
                    startsCreatingLabel: editorLabelForm
                )
            }

            dueRow

            labelChips

            if card.noteID != nil || boardBadge != nil {
                HStack(spacing: 6) {
                    if card.noteID != nil { linkChip }
                    Spacer(minLength: 0)
                    if let boardBadge {
                        // Tinted like a label chip, down to the opacities: the text stays
                        // primary because a caption2 painted in the palette colour is the
                        // first thing to go unreadable in light appearance.
                        Text(boardBadge.name)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color(boardBadge.color).opacity(0.3)))
                            .overlay(Capsule().strokeBorder(Color(boardBadge.color).opacity(0.75)))
                            .accessibilityIdentifier("card.boardBadge")
                    }
                }
            }

            notesSection
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { cellBackground }
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
        // The editor writes this very card, so take what it wrote. The inequality guard is
        // what keeps this from fighting the cell's own field: a commit from here comes back
        // identical, and the notes are left alone while the caret is in them.
        .onChange(of: card.title) { _, new in if new != title { title = new } }
        .onChange(of: card.body) { _, new in
            let text = new ?? ""
            if !notesFocused, text != body_ { body_ = text }
        }
        // Changing the board setting overrides whatever this card was left on — that is the
        // point of "fold all": one card the user opened earlier must not survive it.
        .onChange(of: display) { _, _ in expanded = notesOpenByDefault }
    }

    // MARK: - Cell

    /// The card's colour paints the whole cell — fill and border both, the way a calendar
    /// paints an event. It is a wash over the material rather than a flat colour: the board
    /// is glass, and an opaque card sitting on it looks pasted on.
    ///
    /// Selection still wins the border. A colour is how a card is filed; selection is where
    /// the keyboard is, and that has to be readable on a card of any colour.
    private var cellBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let tint = card.color.map { Color($0) }
        return shape
            .fill(.thinMaterial)
            .overlay { shape.fill(tint?.opacity(0.22) ?? .clear) }
            .overlay {
                shape.strokeBorder(
                    isSelected
                        ? AnyShapeStyle(MeatPadGlass.violet.opacity(0.9))
                        : AnyShapeStyle(tint?.opacity(0.7) ?? .white.opacity(0.10)),
                    lineWidth: isSelected ? 1.5 : 1
                )
            }
            .shadow(color: .black.opacity(isSelected ? 0.28 : 0.16), radius: isSelected ? 7 : 3, y: 2)
    }

    // MARK: - Menu

    /// One set of card actions, shown both from the ⋯ button and from a right-click — a card
    /// that only answers to the context menu hides half its features.
    @ViewBuilder
    private var cardMenu: some View {
        Menu("Due Date") {
            Button("Today") { setDue(CardDue.today()) }
            Button("Tomorrow") { setDue(CardDue.morning(daysFromNow: 1)) }
            Button("Next Week") { setDue(CardDue.morning(daysFromNow: 7)) }
            Button("Custom…") {
                if card.due == nil { setDue(CardDue.today()) }
                editingDue = true
            }
            if card.due != nil {
                Divider()
                Button("Remove Due Date") { update { $0.due = nil } }
            }
        }
        Menu("Labels") {
            ForEach(store.labels) { label in
                Toggle(label.name, isOn: labelBinding(label.id))
            }
            if !store.labels.isEmpty { Divider() }
            Button("New Label…") {
                editorLabelForm = true
                editorShown = true
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

    // MARK: - Labels

    /// One tinted chip per label, in the store's order so a card's labels read the same way
    /// everywhere. Hidden entirely when the card has none — an empty row would cost every
    /// card 10pt of height for nothing.
    @ViewBuilder
    private var labelChips: some View {
        let labels = store.labels.filter { card.labelIDs?.contains($0.id) ?? false }
        if !labels.isEmpty {
            HStack(spacing: 4) {
                ForEach(labels) { label in
                    Text(label.name)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color(label.color).opacity(0.3)))
                        .overlay(Capsule().strokeBorder(Color(label.color).opacity(0.75)))
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// Writes through `updateCard`, the same path every other card edit takes — a label is
    /// just another field on the card, not its own store concept.
    private func labelBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { card.labelIDs?.contains(id) ?? false },
            set: { on in
                update { card in
                    var ids = card.labelIDs ?? []
                    ids.removeAll { $0 == id }
                    if on { ids.append(id) }
                    card.labelIDs = ids.isEmpty ? nil : ids
                }
            }
        )
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
            get: { card.due ?? CardDue.today() },
            set: { newValue in setDue(newValue) }
        )
    }

    /// Setting a date is the first moment a reminder can matter — and the only honest moment
    /// to ask for notification permission in an app that has no account and no onboarding.
    private func setDue(_ date: Date) {
        update { $0.due = date }
        Task { await DueNotifier.shared.requestAuthorizationIfNeeded() }
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
        expanded = notesOpenByDefault
        refreshSummarizable()
    }

    /// A card with no notes never opens its field, whatever the board setting says — a column
    /// of empty "Notes" boxes is less card, not more.
    private var notesOpenByDefault: Bool {
        display.notesOpen && !body_.isEmpty
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
