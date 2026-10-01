import SwiftUI
import AppKit
import MeatPadKit

/// One card, editable in place — the board is the editor. Rows separated by hairlines, the
/// way `CardEditor` groups its own, and every row is a label until it is clicked: that is what
/// leaves the mouse-down to `.draggable`, so the card drags from its title instead of only
/// from its padding. The label is `LinkableText`, which keeps a URL in the text clickable
/// without taking the clicks that belong to editing and dragging. Height follows content — the title wraps rather than truncates, and the
/// notes fold down to their first line. `⋯` opens `CardEditor` for everything at once.
/// A board icon, decoded once instead of once per layout pass. Every card in the All Boards
/// view draws the badge of the board it belongs to, so the uncached read was a file read plus
/// an image decode per card per pass — the single most expensive thing on that board's scroll.
/// Keyed by path, which is safe here: `AttachmentStore.add` names every file after a fresh
/// UUID, so a replaced board image never reuses its predecessor's URL. Unlike
/// `AttachmentThumbnail`'s cache the key carries no pixel size, because this one hands back
/// the decoded file itself and every caller only ever draws it (`Image(nsImage:).resizable()`
/// reads the image, it does not resize it) — nothing here sets `NSImage.size` the way
/// `AboutPanel` does to its own mark.
enum BoardIconCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200
        return cache
    }()

    static func image(at url: URL?) -> NSImage? {
        guard let url else { return nil }
        let key = url.path as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

struct CardView: View {
    @ObservedObject var store: BoardStore
    let boardID: UUID
    let card: Card
    /// The board this card came from, badged only in the All Boards overview — in a view that
    /// stacks four boards into one column, the badge is the only thing saying where a card
    /// came from. The whole board rather than a name: the badge draws the board's icon too,
    /// and its colour comes from the store, which four grey badges would not say quickly.
    var boardBadge: Board?
    let isDone: Bool
    let isSelected: Bool
    /// How much of the card to draw. Owned by the board, not the card — "fold everything"
    /// is a board-wide gesture — but a card can still open its own notes from the ⋯ menu
    /// until the setting next changes.
    let display: CardDisplay
    /// "Present Card" in the card's menu. nil where the board has nowhere to present it.
    var onPresent: (() -> Void)? = nil
    /// The board's search query, marked wherever it hits the title or notes on the face.
    var highlight: String = ""

    /// Which of the two text rows currently holds a live field. The face renders a label until
    /// a row is clicked: an `NSTextField` takes every mouse-down for caret placement, which is
    /// why a card could only be dragged by its padding. A label lets `.draggable` see the press.
    private enum Field: Hashable { case title, notes }
    @State private var editing: Field?
    @FocusState private var focus: Field?

    @State private var title = ""
    @State private var body_ = ""
    /// What `commit()` last wrote, so the two `.onChange` handlers below can tell "our own
    /// write echoing back" from "someone else changed the card" (undo, redo, the ⋯ editor).
    @State private var committedTitle = ""
    @State private var committedBody: String?
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
    /// Flashed by every copy, so the Copy icon in the action row shows the checkmark.
    @State private var copied = false
    /// On by default — the user asked for inline markdown on card faces, off only when this
    /// setting says so. Board-wide, not per-card: a mixed board reading half-rendered would be
    /// worse than either extreme.
    @AppStorage("board.markdown") private var markdown = true
    /// Icon colours (Settings ▸ Boards): two keys for the whole palette rather than one wrapper
    /// per kind, so a card watches two strings, not eleven. `iconPalette` reads them.
    @AppStorage(CardIconPalette.enabledKey) private var coloredIcons = false
    @AppStorage(CardIconPalette.colorsKey) private var iconColors = ""
    /// The field editor's own drag registration, saved off while a title/notes field is
    /// focused — see `suspendFieldEditorDragTypes` below.
    @State private var suspendedFieldEditor: NSTextView?
    @State private var suspendedDraggedTypes: [NSPasteboard.PasteboardType] = []
    @Environment(\.openWindow) private var openWindow
    /// How much bigger than normal to draw — presentation mode, or the present overlay. Every
    /// type and tile size below is multiplied by it; at 1 the card is what it always was.
    @Environment(\.cardScale) private var scale

    private func fontSize(_ style: NSFont.TextStyle) -> CGFloat {
        NSFont.preferredFont(forTextStyle: style).pointSize * scale
    }

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
                                size: 44 * scale, limit: 4, identifier: "card.attachment",
                                dragTitle: card.title, owner: card.id)
                    .padding(.vertical, 7)
            }
            HairlineDivider()
            // Not in `.compact`, for the density's own reason: the row is one more line on
            // every card. The right-click menu and ⋯ still carry every action there.
            if display != .compact { actionRow }
            notesSection
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { cellBackground }
        .opacity(card.archived != nil ? 0.55 : 1)
        .contextMenu { cardMenu.labelStyle(.titleAndIcon) }
        // Calendar's own shape for "pick an exact time": a popover, not a field wedged into
        // the card — the card face carries the date, never the picker.
        .popover(isPresented: $editingDue) {
            DatePicker("", selection: dueBinding, displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(12)
        }
        .onAppear { load() }
        // A card can disappear mid-edit (scrolled off, dragged to another column) without ever
        // firing the blur that normally restores the field editor's drag types — this is the
        // other side of `suspendFieldEditorDragTypes` below.
        .onDisappear { restoreFieldEditorDragTypes() }
        // The same view instance is reused when a card moves column; reload so drafts follow it.
        .onChange(of: card.id) { _, _ in titleDebouncer.cancel(); bodyDebouncer.cancel(); editing = nil; load() }
        // Our own commits echo back as exactly what we wrote; anything else is an undo, a redo, or
        // the ⋯ editor writing this card. Take it even while the caret is in the field — otherwise the
        // stale draft re-commits over it on blur and the undo silently undoes itself.
        .onChange(of: card.title) { _, new in
            if new != committedTitle { committedTitle = new; title = new }
        }
        .onChange(of: card.body) { _, new in
            if new != committedBody { committedBody = new; body_ = new ?? "" }
        }
        // Changing the board setting overrides whatever this card was left on — that is the
        // point of "fold all": one card the user opened earlier must not survive it.
        .onChange(of: display) { _, _ in expanded = notesOpenByDefault }
        // Blur = commit. Whatever took focus away (a click elsewhere, Tab, the editor popover)
        // the field's text must land before the row turns back into Text.
        .onChange(of: focus) { old, new in
            if old == .title, new != .title {
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
            // Drag types come off the instant a field takes focus (nil -> some) and go back on
            // the instant it's fully blurred (some -> nil) — switching between this card's own
            // two fields (old and new both non-nil) is still "a field is focused" throughout,
            // so it neither re-suspends nor restores.
            if old == nil, new != nil { suspendFieldEditorDragTypes() }
            if old != nil, new == nil { restoreFieldEditorDragTypes() }
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
                    .font(.system(size: fontSize(.body), weight: .semibold))
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
                    .onChange(of: title) { _, _ in
                        titleDebouncer.call { commit() }
                        if editing == .title { FieldEditorScroll.revealCaret() }
                    }
                    .accessibilityIdentifier("card.title")
            } else {
                LinkableText(
                    text: faceTitle,
                    font: .systemFont(ofSize: fontSize(.body), weight: .semibold),
                    color: title.isEmpty ? .secondaryLabelColor : .labelColor,
                    lineLimit: display.titleLines,
                    markdown: markdown,
                    // Never on the grey "Title" placeholder: it is chrome, not the card's text.
                    highlight: title.isEmpty ? "" : highlight
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background { editTapLayer { editing = .title; focus = .title } }
                    // One element for the row, standing in for the `Text` this used to be:
                    // `.isStaticText` keeps it a StaticText for VoiceOver and for the tests
                    // that read a face, and the value carries the text because that is where
                    // an AXStaticText's content lives — the label alone reads back empty.
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isStaticText)
                    .accessibilityLabel(faceTitleAX)
                    .accessibilityValue(faceTitleAX)
                    // A tap gesture is invisible to VoiceOver, so the row still offers a named
                    // action — but never the `.isButton` trait: that turns the element into an
                    // AXButton whose value is always "", so both VoiceOver and a UI test reading
                    // this row's text get nothing back. The row stays static text; the rotor
                    // just grows an "Edit" entry.
                    .accessibilityAction(named: Text("Edit")) { editing = .title; focus = .title }
                    .accessibilityIdentifier("card.title")
            }
            if card.archived != nil {
                Image(systemName: "archivebox")
                    .font(.system(size: fontSize(.caption1)))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("card.archived")
            }
            if summarizing {
                ProgressView().controlSize(.mini)
            }
            // Only while the card has nothing on it. A blank card is what the column's `+`
            // makes, and this is the one-click way to fill it — always visible, because on an
            // otherwise empty card it is the whole point of the card being there.
            if card.isBlank {
                Button(action: pasteFromClipboard) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: fontSize(.body)))
                        .foregroundStyle(.secondary)
                        .frame(width: 22 * scale, height: 18 * scale)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Paste from Clipboard"))
                .accessibilityLabel(Text("Paste from Clipboard"))
                .accessibilityIdentifier("card.paste")
            }
            Button {
                editorLabelForm = false
                editorShown = true
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: fontSize(.body)))
                    .foregroundStyle(.secondary)
                    // A bare glyph is a 13pt target sitting next to a card that answers
                    // clicks itself — miss it and you select the card instead.
                    .frame(width: 22 * scale, height: 18 * scale)
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
            // The popover is its own window: its strip keeps its own Quick Look, as it always
            // had, rather than reaching back to the board's.
            .environment(\.quickLookHost, nil)
        }
    }

    private var faceTitle: String {
        title.isEmpty ? String(localized: "Title") : title
    }

    /// What VoiceOver and the UI tests read for the title. The placeholder is chrome, never
    /// markdown; a real title goes through `CardMarkdown.plain` when markdown is on, so what's
    /// read back matches what `LinkableText` draws instead of the raw `**title**` source.
    private var faceTitleAX: String {
        markdown && !title.isEmpty ? CardMarkdown.plain(faceTitle) : faceTitle
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Copies `text`, then flashes `flag` on and off — long enough to register as feedback
    /// without lingering past the next glance.
    private func copyAndFlash(_ text: String, flag: Binding<Bool>) {
        copyToPasteboard(text)
        flag.wrappedValue = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            flag.wrappedValue = false
        }
    }

    /// Fills a blank card from the clipboard, split the same way a paste into the column's
    /// add-card field is: lead sentence as the title, the rest as the notes. One card, never
    /// several — the multi-card question belongs to the column field, where the paste creates
    /// the cards; here there is already exactly one card to fill.
    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              let draft = CardTextSplit.single(from: text) else { return }
        update {
            $0.title = draft.title
            $0.body = draft.body
        }
    }

    private func copyText() { copyAndFlash(card.clipboardText, flag: $copied) }
    private func copyTitleOnly() { copyAndFlash(card.title, flag: $copied) }
    private func copyNotesOnly() { copyAndFlash((card.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines), flag: $copied) }

    /// "Split into Cards". A draft still waiting on its debounce is committed first, inside
    /// the same undo group, so the split works on what the card shows and one ⌘Z takes the
    /// whole gesture back.
    private func splitIntoCards(_ mode: CardSplitMode) {
        titleDebouncer.cancel()
        bodyDebouncer.cancel()
        try? store.grouped {
            commit()
            try store.splitCard(boardID: boardID, cardID: card.id, mode: mode)
        }
    }

    /// Notes, each under a title written for it. The titles come first and the store is
    /// called once, so the split is still one undo step and one write — titling the cards
    /// afterwards would be a dozen. A line the model can't title (unsupported language, no
    /// on-device model, macOS 14) gets its opening words instead; a line that short already
    /// is its own title and keeps no notes. The store drops the titles if the card changed
    /// while they were being written.
    private func splitIntoNotesWithTitles() {
        titleDebouncer.cancel()
        bodyDebouncer.cancel()
        commit()
        let id = card.id
        let lines = CardTextSplit.lines(from: title + "\n" + body_)
        summarizing = true
        Task {
            var titles: [String] = []
            for line in lines {
                let lead = CardTextSplit.headline(of: line)
                titles.append(lead == line ? lead : await CardSummarizer.title(for: line, minimumLength: 0) ?? lead)
            }
            summarizing = false
            try? store.splitCard(boardID: boardID, cardID: id, mode: .notes(titles: titles))
        }
    }

    /// The empty-notes field doubles as the only in-app hint that card text takes markdown —
    /// gated on the setting that renders it, or it would advertise syntax the card shows
    /// literally. The idle face keeps its plain "Add Notes"; a hint belongs where you type.
    private var notesPlaceholder: String {
        markdown ? String(localized: "Notes — **bold**, *italic*") : String(localized: "Notes")
    }

    private var faceNotes: String {
        body_.isEmpty ? String(localized: "Add Notes") : (notesOpen ? body_ : firstLine)
    }

    /// Whether the face draws the whole notes. Folded notes show one line, so a search hit on
    /// the third would leave a card in the results with no visible reason — while the query
    /// hits the notes they draw whole. Derived rather than written into `expanded`, so
    /// clearing the search puts the card back exactly as the user left it.
    private var notesOpen: Bool {
        guard !expanded else { return true }
        let needle = highlight.trimmingCharacters(in: .whitespacesAndNewlines)
        return !needle.isEmpty && body_.localizedStandardContains(needle)
    }

    /// Same rule as `faceTitleAX`, for the notes row.
    private var faceNotesAX: String {
        markdown && !body_.isEmpty ? CardMarkdown.plain(faceNotes) : faceNotes
    }

    /// "Click this row to edit it" — as a layer BEHIND the text rather than a gesture on it.
    /// `LinkableText` hands back every click that didn't land on a link, and this is what
    /// catches them; a gesture on the text itself would swallow the link clicks too.
    ///
    /// A ⌘/⇧-click is a selection gesture, not an edit one — the board's row-level tap
    /// (`.simultaneousGesture` in `BoardColumnsView.cardRow`) still fires either way, so this
    /// only has to skip starting the field. The `.accessibilityAction(named: "Edit")` handlers
    /// at the two call sites are unaffected — VoiceOver has no modifier keys to hold.
    private func editTapLayer(_ begin: @escaping () -> Void) -> some View {
        Color.clear.contentShape(Rectangle()).onTapGesture {
            guard NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty else { return }
            begin()
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

    /// The window's field editor is one `NSTextView` shared by every text field in it, and it
    /// registers for dragged types — so dropping an image on a card while its title or notes is
    /// focused lands as inserted text (a file URL) instead of ever reaching the column's
    /// `onDrop` attachment handler underneath. The fix has to be scoped IN TIME, never
    /// globally: unregister the instant this field takes focus, put it back the instant it
    /// blurs (`restoreFieldEditorDragTypes`), so every other field in the window keeps
    /// accepting drops as normal. Same async gap as `moveCaretToEnd`: first responder only
    /// becomes the field editor a turn after `focus` changes, so this has to wait a turn too,
    /// or it finds the previous field's editor (or none yet).
    private func suspendFieldEditorDragTypes() {
        DispatchQueue.main.async {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            suspendedDraggedTypes = editor.registeredDraggedTypes
            editor.unregisterDraggedTypes()
            suspendedFieldEditor = editor
        }
    }

    /// Undoes `suspendFieldEditorDragTypes`, putting back exactly what was there. Called on
    /// blur and from `.onDisappear`, so a card that goes away mid-edit never leaves the shared
    /// field editor unable to accept drops for the rest of the window's life.
    private func restoreFieldEditorDragTypes() {
        guard let editor = suspendedFieldEditor else { return }
        editor.registerForDraggedTypes(suspendedDraggedTypes)
        suspendedFieldEditor = nil
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

    /// The card's actions, grouped. One list drives both places they appear — the right-click
    /// menu shows each as a submenu with its name, the action row as an icon that opens the
    /// same menu — so the two cannot drift apart. A card that only answers to the context
    /// menu would hide half its features; one that only answers to the row would hide them
    /// from anyone who right-clicks.
    private enum Category: CaseIterable {
        case move, due, labels, copy, split

        var title: LocalizedStringKey {
            switch self {
            case .move: "Move to"
            case .due: "Due Date"
            case .labels: "Labels"
            case .copy: "Copy"
            case .split: "Split into Cards"
            }
        }

        /// The icon colour this category answers to; its sub-items inherit it.
        var kind: CardIconKind {
            switch self {
            case .move: .move
            case .due: .due
            case .labels: .labels
            case .copy: .copy
            case .split: .split
            }
        }

        var symbol: String { kind.symbol }

        var identifier: String {
            switch self {
            case .move: "card.move"
            case .due: "card.due"
            case .labels: "card.labels"
            case .copy: "card.copy"
            case .split: "card.split"
            }
        }
    }

    /// A category with nothing to offer is absent, not disabled: a blank card has nothing to
    /// copy, a one-line card nothing to split, a card alone in its board nowhere to move.
    private var categories: [Category] {
        Category.allCases.filter { category in
            switch category {
            case .move: !otherColumns.isEmpty
            case .copy: !card.isBlank
            case .split: card.splitLines.count >= 2
            case .due, .labels: true
            }
        }
    }

    @ViewBuilder
    private func items(for category: Category) -> some View {
        switch category {
        case .move: moveItems
        case .due: dueItems
        case .labels: labelItems
        case .copy: copyItems
        case .split: splitItems
        }
    }

    /// The icon settings, decoded once per body pass (`CardIconPalette` memoises the JSON).
    private var iconPalette: CardIconPalette {
        CardIconPalette(enabled: coloredIcons, json: iconColors)
    }

    /// Every menu entry is an icon and a name. The icon is an `Image(nsImage:)` made by
    /// `CardIcon`, never `Label(systemImage:)`, which a macOS menu draws without its icon.
    private func menuLabel(_ title: LocalizedStringKey, _ symbol: String, _ kind: CardIconKind) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(nsImage: CardIcon.image(symbol, color: iconPalette.color(for: kind)))
        }
    }

    private func item(_ kind: CardIconKind, _ title: LocalizedStringKey, _ symbol: String,
                      role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) { menuLabel(title, symbol, kind) }
    }

    @ViewBuilder
    private var cardMenu: some View {
        ForEach(categories, id: \.self) { category in
            Menu {
                items(for: category)
            } label: {
                menuLabel(category.title, category.symbol, category.kind)
            }
        }
        Divider()
        item(.notes, expanded ? "Hide Notes" : "Show Notes", CardIconKind.notes.symbol) { expanded.toggle() }
        if let onPresent {
            item(.present, "Present Card", CardIconKind.present.symbol) { onPresent() }
        }
        if summarizable {
            item(.summarize, "Summarize into Title", CardIconKind.summarize.symbol) { summarize() }
        }
        if card.noteID != nil {
            item(.unlink, "Unlink", CardIconKind.unlink.symbol) { update { $0.noteID = nil } }
        }
        Divider()
        item(.archive, card.archived == nil ? "Archive Card" : "Unarchive Card",
             card.archived == nil ? CardIconKind.archive.symbol : "tray.and.arrow.up") {
            try? store.setArchived(boardID: boardID, cardIDs: [card.id], card.archived == nil)
        }
        item(.delete, "Delete Card", CardIconKind.delete.symbol, role: .destructive) {
            bodyDebouncer.cancel()
            try? store.deleteCard(boardID: boardID, cardID: card.id)
        }
    }

    /// Every other column of the card's own board, in the board's order — the card's own
    /// `boardID`, so the All Boards view offers the same. Each with its column's look, so the
    /// menu reads like the header it points at.
    @ViewBuilder
    private var moveItems: some View {
        ForEach(otherColumns) { column in
            Button { move(to: column) } label: {
                Label {
                    Text(column.name)
                } icon: {
                    if let image = ColumnMenuIcon.image(for: column, in: store) {
                        Image(nsImage: image)
                    } else {
                        Image(nsImage: CardIcon.image("rectangle.split.3x1", color: iconPalette.color(for: .move)))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var dueItems: some View {
        item(.due, "Today", "sun.max") { setDue(CardDue.today()) }
        item(.due, "Tomorrow", "sunrise") { setDue(CardDue.morning(daysFromNow: 1)) }
        item(.due, "Next Week", "calendar.badge.clock") { setDue(CardDue.morning(daysFromNow: 7)) }
        item(.due, "Custom…", "calendar") {
            if card.due == nil { setDue(CardDue.today()) }
            editingDue = true
        }
        if card.due != nil {
            Divider()
            item(.due, "Remove Due Date", "calendar.badge.minus") { update { $0.due = nil } }
        }
    }

    @ViewBuilder
    private var labelItems: some View {
        ForEach(store.labels) { label in
            Toggle(label.name, isOn: labelBinding(label.id))
        }
        if !store.labels.isEmpty { Divider() }
        item(.labels, "New Label…", "plus") {
            editorLabelForm = true
            editorShown = true
        }
    }

    /// Each copy only when it would put something on the pasteboard: a card without notes
    /// offers no "Copy Notes".
    @ViewBuilder
    private var copyItems: some View {
        item(.copy, "Copy Text", "doc.on.doc", action: copyText)
        if !card.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            item(.copy, "Copy Title", "textformat", action: copyTitleOnly)
        }
        if !(card.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            item(.copy, "Copy Notes", "note.text", action: copyNotesOnly)
        }
    }

    @ViewBuilder
    private var splitItems: some View {
        item(.split, "Split into Titles", "textformat") { splitIntoCards(.titles) }
        item(.split, "Split into Notes", "note.text") { splitIntoCards(.notes()) }
        item(.split, "Split into Notes with Titles", "sparkles", action: splitIntoNotesWithTitles)
    }

    // MARK: - Action row

    /// Below the title's separator and above the notes, so the notes can take the card's full
    /// width instead of sharing their line with two buttons. Icons only — the name is the
    /// tooltip and the accessibility label — each opening the category's menu.
    private var actionRow: some View {
        HStack(spacing: 2 * scale) {
            ForEach(categories, id: \.self) { category in
                let flashing = category == .copy && copied
                Menu { items(for: category).labelStyle(.titleAndIcon) } label: {
                    Image(systemName: flashing ? "checkmark.circle.fill" : category.symbol)
                        .font(.system(size: fontSize(.callout)))
                        .foregroundStyle(flashing ? AnyShapeStyle(.green) : iconStyle(category.kind))
                        .frame(width: 22 * scale, height: 18 * scale)
                        .contentShape(Rectangle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(category.title)
                .accessibilityLabel(category.title)
                .accessibilityValue(flashing ? "copied" : "")
                .accessibilityIdentifier(category.identifier)
            }
            Spacer(minLength: 0)
            if let onPresent {
                Button(action: onPresent) {
                    Image(systemName: CardIconKind.present.symbol)
                        .font(.system(size: fontSize(.callout)))
                        .foregroundStyle(iconStyle(.present))
                        .frame(width: 22 * scale, height: 18 * scale)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Present Card"))
                .accessibilityLabel(Text("Present Card"))
                .accessibilityIdentifier("card.present")
            }
            Button {
                // Folding the row out from under a live field would leave the caret in a
                // view that is on its way out; hand focus back first, which also commits.
                if editing == .notes { focus = nil }
                expanded.toggle()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11 * scale, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
                    .frame(width: 22 * scale, height: 18 * scale)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .animation(.snappy(duration: 0.18), value: expanded)
            .help(expanded ? String(localized: "Hide Notes") : String(localized: "Show Notes"))
            .accessibilityIdentifier("card.notesToggle")
        }
        .padding(.top, 4)
    }

    /// The action row's icon colour: the kind's own when colouring is on, as quiet as ever
    /// when it is off.
    private func iconStyle(_ kind: CardIconKind) -> AnyShapeStyle {
        iconPalette.color(for: kind).map { AnyShapeStyle(Color(nsColor: $0)) } ?? AnyShapeStyle(.secondary)
    }

    private var otherColumns: [BoardColumn] {
        guard let board = store.boards.first(where: { $0.id == boardID }) else { return [] }
        return store.columns(for: board).filter { $0.id != card.columnID }
    }

    /// To the bottom of the destination, where a card dragged into the column's empty space
    /// lands too. `moveCard` registers its own undo, so ⌘Z brings the card back.
    private func move(to column: BoardColumn) {
        guard let board = store.boards.first(where: { $0.id == boardID }) else { return }
        let end = store.cards(in: board, column: column.id).count
        try? store.moveCard(id: card.id, boardID: boardID, toColumn: column.id, index: end)
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
                        .font(.system(size: 10 * scale, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 6 * scale)
                        .padding(.vertical, 2 * scale)
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
                .font(.system(size: fontSize(.caption1)))
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

    /// Folded: the first line of the notes, in the same type the editor uses. Open: the whole
    /// text. Either way a click on the text edits; the fold chevron lives in the action row.
    private var notesSection: some View {
        Group {
            if editing == .notes {
                // axis: .vertical grows with its content instead of reserving a fixed block,
                // and unlike TextEditor it takes the caret on a single click. No upper line
                // limit: a capped field clips the rest of the text AND eats the scroll wheel,
                // so the column underneath can't be scrolled while the pointer is over it.
                TextField(notesPlaceholder, text: $body_, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: fontSize(.callout)))
                    .lineLimit(1...)
                    .focused($focus, equals: .notes)
                    .newlineOnModifiedReturn()
                    .onAppear {
                        // Same seam as the title field's onAppear above: the tap sets `focus`
                        // once, this sets it again after SwiftUI's insert transaction closes,
                        // which is the assignment that actually lands.
                        DispatchQueue.main.async { focus = .notes }
                    }
                    .onChange(of: body_) { _, _ in
                        bodyDebouncer.call { commit() }
                        // The field grows with its text; follow the caret down the column.
                        if editing == .notes { FieldEditorScroll.revealCaret() }
                    }
                    .accessibilityIdentifier("card.notes")
            } else {
                LinkableText(
                    text: faceNotes,
                    font: .systemFont(ofSize: fontSize(.callout)),
                    color: body_.isEmpty ? .secondaryLabelColor : .labelColor,
                    lineLimit: notesOpen ? 0 : 1,
                    markdown: markdown,
                    highlight: body_.isEmpty ? "" : highlight
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background { editTapLayer { expanded = true; editing = .notes; focus = .notes } }
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isStaticText)
                    .accessibilityLabel(faceNotesAX)
                    .accessibilityValue(faceNotesAX)
                    // No `.isButton` trait here either — see the title row's comment above.
                    .accessibilityAction(named: Text("Edit")) { expanded = true; editing = .notes; focus = .notes }
                    .accessibilityIdentifier("card.notes")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                // unreadable in light appearance. The identifier stays on the name, not the
                // stack: a container identifier takes the children's with it, and the icon
                // has to stay readable on its own.
                let color = Color(store.color(forBoard: boardBadge.id))
                HStack(spacing: 3 * scale) {
                    badgeIcon(boardBadge)
                    Text(boardBadge.name)
                        .accessibilityIdentifier("card.boardBadge")
                }
                .font(.system(size: fontSize(.caption2)))
                .padding(.horizontal, 6 * scale)
                .padding(.vertical, 2 * scale)
                .background(Capsule().fill(color.opacity(0.3)))
                .overlay(Capsule().strokeBorder(color.opacity(0.75)))
            }
        }
        .padding(.vertical, 7)
    }

    /// The board's own icon, ahead of its name in the badge: image, else emoji, else nothing
    /// at all — a board with no icon keeps the plain name badge it has always had. Read as
    /// text for the same reason the sidebar row's is: a thumbnail has no value to read.
    @ViewBuilder
    private func badgeIcon(_ board: Board) -> some View {
        let image = BoardIconCache.image(at: store.boardImageURL(board.id))
        if image != nil || board.icon != nil {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 10 * scale, height: 10 * scale)
                        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                } else {
                    Text(board.icon ?? "")
                }
            }
            .accessibilityRepresentation { Text(image != nil ? "image" : (board.icon ?? "")) }
            .accessibilityIdentifier("card.boardBadge.icon.\(board.id.uuidString)")
        }
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
            .font(.system(size: fontSize(.caption2)))
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
        committedTitle = card.title
        committedBody = card.body
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
        // The store trims the title before persisting (`trimmedCardTitle`), so this guard must
        // compare the same trimmed value — otherwise a trailing-space-only edit would diverge
        // from the store's echo and the space would vanish from the draft on the next resync.
        // An empty title is a title: the column's `+` makes exactly that, and clearing the
        // field has to be able to get back to it.
        let edited = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let editedBody = body_.isEmpty ? nil : body_
        // Recorded even on the no-op path below: this is what the card's own values are about
        // to be (or already are), and the `.onChange` handlers above must not mistake either
        // for an external change and resync the draft over what the user just typed.
        committedTitle = edited
        committedBody = editedBody
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
