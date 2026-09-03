import SwiftUI
import MeatPadKit

/// One card, editable in place — the board is the editor. Rows separated by hairlines, the
/// way `CardEditor` groups its own, and every row is `Text` until it is clicked: that is what
/// leaves the mouse-down to `.draggable`, so the card drags from its title instead of only
/// from its padding. Height follows content — the title wraps rather than truncates, and the
/// notes fold down to their first line. `⋯` opens `CardEditor` for everything at once.
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

    /// Which of the two text rows currently holds a live field. The face renders `Text` until
    /// a row is clicked: an `NSTextField` takes every mouse-down for caret placement, which is
    /// why a card could only be dragged by its padding. Text lets `.draggable` see the press.
    private enum Field: Hashable { case title, notes }
    @State private var editing: Field?
    @FocusState private var focus: Field?

    @State private var title = ""
    @State private var body_ = ""
    @State private var expanded = false
    @State private var titleDebouncer = Debouncer(delay: 0.5)
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
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow
            if hasLabels { HairlineDivider(); labelChips }
            if card.due != nil { HairlineDivider(); dueRow }
            if card.noteID != nil || boardBadge != nil { HairlineDivider(); linkRow }
            // Not in `.compact`: that density exists to fit a column on screen, and a row of
            // 44pt tiles is the tallest thing a card can carry.
            if display != .compact, let names = card.attachments, !names.isEmpty {
                HairlineDivider()
                AttachmentStrip(urls: names.map { store.attachmentURL(cardID: card.id, name: $0) },
                                size: 44, limit: 4, identifier: "card.attachment")
                    .padding(.vertical, 7)
            }
            HairlineDivider()
            notesSection
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
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
        .onChange(of: card.id) { _, _ in titleDebouncer.cancel(); bodyDebouncer.cancel(); editing = nil; load() }
        // The editor writes this very card, so take what it wrote. The inequality guard is
        // what keeps this from fighting the cell's own field: a commit from here comes back
        // identical, and a row being typed into is left alone.
        .onChange(of: card.title) { _, new in if editing != .title, new != title { title = new } }
        .onChange(of: card.body) { _, new in
            let text = new ?? ""
            if editing != .notes, text != body_ { body_ = text }
        }
        // Changing the board setting overrides whatever this card was left on — that is the
        // point of "fold all": one card the user opened earlier must not survive it.
        .onChange(of: display) { _, _ in expanded = notesOpenByDefault }
        // Blur = commit. Whatever took focus away (a click elsewhere, Tab, the editor popover)
        // the field's text must land before the row turns back into Text.
        .onChange(of: focus) { old, new in
            if old == .title, new != .title {
                // A blank title is never stored, so put the card's own back — otherwise the
                // idle row draws its grey placeholder over a card that still has a name.
                if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { title = card.title }
                titleDebouncer.cancel()
                commit()
            }
            if old == .notes, new != .notes { bodyDebouncer.cancel(); commit() }
            // Only the row that lost focus goes back to Text. Clicking the other row sets
            // `editing` in the same pass that drops this field — that click must survive.
            if new == nil, editing == old { editing = nil }
            // The caret is placed here rather than in the field's own onAppear: only once
            // focus has landed is the field editor AppKit's first responder, which is what
            // `moveCaretToEnd` reaches for.
            if new != nil { moveCaretToEnd() }
        }
    }

    // MARK: - Title

    private var titleRow: some View {
        HStack(alignment: .top, spacing: 6) {
            if editing == .title {
                // axis: .vertical so a long title wraps onto as many lines as it needs, up to
                // what the board's display setting allows. No `newlineOnModifiedReturn` here
                // on purpose: wrapping is layout, and a title with a literal newline in it is
                // a title nothing can render.
                TextField("Title", text: $title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body.weight(.semibold))
                    .lineLimit(display.titleLines)
                    .focused($focus, equals: .title)
                    .onSubmit { focus = nil }
                    .onAppear {
                        // The tap below already set `focus`, but SwiftUI can ignore a focus
                        // assignment made in the same transaction that inserts this field —
                        // and `onAppear` still runs inside that transaction. Setting it again
                        // a turn later, after the transaction has closed, is what actually
                        // moves first responder.
                        DispatchQueue.main.async { focus = .title }
                    }
                    .onChange(of: title) { _, _ in titleDebouncer.call { commit() } }
                    .accessibilityIdentifier("card.title")
            } else {
                Text(title.isEmpty ? String(localized: "Title") : title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(title.isEmpty ? .secondary : .primary)
                    .lineLimit(display.titleLines)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { editing = .title; focus = .title }
                    // A tap gesture is invisible to VoiceOver, so the row still offers a named
                    // action — but never the `.isButton` trait: that turns the element into an
                    // AXButton whose value is always "", so both VoiceOver and a UI test reading
                    // this row's text get nothing back. Text stays Text; the rotor just grows
                    // an "Edit" entry.
                    .accessibilityAction(named: Text("Edit")) { editing = .title; focus = .title }
                    .accessibilityIdentifier("card.title")
            }
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
        .padding(.vertical, 7)
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
    }

    /// A field that has just taken focus selects everything; a click on a title means
    /// "append", so put the caret at the end instead. Same first-responder seam as
    /// `newlineOnModifiedReturn` — the vertical-axis field's editor is an NSTextView.
    private func moveCaretToEnd() {
        DispatchQueue.main.async {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        }
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

    /// Asked by the body before it draws a separator, so a card with no labels doesn't get a
    /// hairline with nothing under it.
    private var hasLabels: Bool {
        store.labels.contains { card.labelIDs?.contains($0.id) ?? false }
    }

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
            .padding(.vertical, 7)
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
            .padding(.vertical, 7)
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

    /// Folded: the first line of the notes, in the same type the editor uses, with a chevron
    /// at the trailing edge (where the editor keeps its tag button). Open: the whole text.
    /// Either way a click on the text edits; only the chevron folds.
    private var notesSection: some View {
        HStack(alignment: .top, spacing: 6) {
            if editing == .notes {
                // axis: .vertical grows with its content instead of reserving a fixed block,
                // and unlike TextEditor it takes the caret on a single click. No upper line
                // limit: a capped field clips the rest of the text AND eats the scroll wheel,
                // so the column underneath can't be scrolled while the pointer is over it.
                TextField("Notes", text: $body_, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .lineLimit(1...)
                    .focused($focus, equals: .notes)
                    .newlineOnModifiedReturn()
                    .onAppear {
                        // Same seam as the title field's onAppear above: the tap sets `focus`
                        // once, this sets it again after SwiftUI's insert transaction closes,
                        // which is the assignment that actually lands.
                        DispatchQueue.main.async { focus = .notes }
                    }
                    .onChange(of: body_) { _, _ in bodyDebouncer.call { commit() } }
                    .accessibilityIdentifier("card.notes")
            } else {
                Text(body_.isEmpty ? String(localized: "Add Notes") : (expanded ? body_ : firstLine))
                    .font(.callout)
                    .foregroundStyle(body_.isEmpty ? .secondary : .primary)
                    .lineLimit(expanded ? nil : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { expanded = true; editing = .notes; focus = .notes }
                    // No `.isButton` trait here either — see the title row's comment above.
                    .accessibilityAction(named: Text("Edit")) { expanded = true; editing = .notes; focus = .notes }
                    .accessibilityIdentifier("card.notes")
            }
            Button {
                // Folding the row out from under a live field would leave the caret in a
                // view that is on its way out; hand focus back first, which also commits.
                if editing == .notes { focus = nil }
                expanded.toggle()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
                    .frame(width: 22, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .animation(.snappy(duration: 0.18), value: expanded)
            .help(expanded ? String(localized: "Hide Notes") : String(localized: "Show Notes"))
            .accessibilityIdentifier("card.notesToggle")
        }
        .padding(.vertical, 7)
    }

    /// What the folded row shows. Empty lines are skipped: a body that starts with a blank
    /// line would otherwise fold to nothing at all.
    private var firstLine: String {
        String(body_.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).first ?? "")
    }

    // MARK: - Linked note

    /// The link and the board badge share a row: one says where the card's text lives, the
    /// other which board it came from, and neither is ever more than a chip wide.
    private var linkRow: some View {
        HStack(spacing: 6) {
            if card.noteID != nil { linkChip }
            Spacer(minLength: 0)
            if let boardBadge {
                // Tinted like a label chip, down to the opacities: the text stays primary
                // because a caption2 painted in the palette colour is the first thing to go
                // unreadable in light appearance.
                Text(boardBadge.name)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color(boardBadge.color).opacity(0.3)))
                    .overlay(Capsule().strokeBorder(Color(boardBadge.color).opacity(0.75)))
                    .accessibilityIdentifier("card.boardBadge")
            }
        }
        .padding(.vertical, 7)
    }

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
        // An empty title would be rejected by the store; keep the stored one instead.
        let edited = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? card.title : title
        let editedBody = body_.isEmpty ? nil : body_
        // Every write through the store is an undo step, and a blur is not an edit: clicking
        // into a row and back out again must not leave a ⌘Z that restores an identical card.
        guard edited != card.title || editedBody != card.body else { return }
        update {
            $0.title = edited
            $0.body = editedBody
        }
        refreshSummarizable()
    }

    private func update(_ change: (inout Card) -> Void) {
        var updated = card
        change(&updated)
        try? store.updateCard(boardID: boardID, card: updated)
    }
}
