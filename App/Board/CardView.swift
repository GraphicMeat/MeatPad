import SwiftUI
import MeatPadKit

/// One card, editable in place — the board is the editor, so nothing opens a pane or a
/// popup. Height follows content: a bare card is two lines tall, and the notes field grows
/// only as far as the text it holds.
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
    @State private var newLabelShown = false
    @State private var labelDraft = ""
    /// The swatch the new-label form is on. Seeded from the store's own next pick, so
    /// creating without touching a swatch gives exactly what the store would have chosen.
    @State private var labelColor = CardLabel.palette[0]
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
            // Anchored to the header row so it points at the ⋯ it came from. A form, not an
            // alert: an alert can hold a text field and nothing else, and a label without a
            // colour to pick is half a label.
            .popover(isPresented: $newLabelShown, arrowEdge: .bottom) { newLabelForm }

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
        Menu("Labels") {
            ForEach(store.labels) { label in
                Toggle(label.name, isOn: labelBinding(label.id))
            }
            if !store.labels.isEmpty { Divider() }
            Button("New Label…") {
                labelDraft = ""
                labelColor = store.suggestedLabelColor
                newLabelShown = true
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

    /// Name plus a swatch, in the palette the store draws from anyway. No custom colour
    /// well here — the filter row already carries a full ColorPicker per label, and this
    /// form exists to get a label made in one gesture.
    private var newLabelForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Name", text: $labelDraft)
                .ringlessField()
                .onSubmit { createLabel() }
                .accessibilityIdentifier("newLabel.name")

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(20), spacing: 6), count: 6), spacing: 6) {
                ForEach(Array(CardLabel.palette.enumerated()), id: \.offset) { index, color in
                    swatch(color, index: index)
                }
            }

            HStack {
                Spacer(minLength: 0)
                Button("Create") { createLabel() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(labelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("newLabel.create")
            }
        }
        .padding(12)
        .frame(width: 212)
    }

    private func swatch(_ color: RGBAColor, index: Int) -> some View {
        Circle()
            .fill(Color(color))
            .frame(width: 20, height: 20)
            .overlay {
                Circle().strokeBorder(.primary.opacity(labelColor == color ? 0.9 : 0), lineWidth: 2)
                    .padding(-2)
            }
            .contentShape(Circle())
            .onTapGesture { labelColor = color }
            .accessibilityIdentifier("newLabel.swatch.\(index)")
            .accessibilityAddTraits(labelColor == color ? [.isSelected] : [])
    }

    /// Creating from a card assigns it there and then — nobody opens this to make a label
    /// they don't want on the card in front of them.
    private func createLabel() {
        guard let label = try? store.createLabel(name: labelDraft, color: labelColor) else { return }
        labelBinding(label.id).wrappedValue = true
        newLabelShown = false
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
