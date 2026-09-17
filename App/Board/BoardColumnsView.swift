import SwiftUI
import UniformTypeIdentifiers
import MeatPadKit

/// The columns for one board, or for every board at once ("All Boards"). In the all-boards
/// view only the global columns are rendered — a board-specific extra column has no shared
/// counterpart, so its cards collect in a trailing read-only "Other" column instead.
struct BoardColumnsView: View {
    @ObservedObject var store: BoardStore
    /// nil = the All Boards overview.
    let board: Board?
    /// Which cards are selected — click/⌘-click/⇧-click on a row, "Select All Cards" in a
    /// column menu, and ⌘A/Esc/⌫/⌦ from the keyboard monitor below all write through this.
    @Binding var selection: BoardSelection
    /// Labels the board is filtered to. Empty = show everything. Owned by the window so the
    /// sidebar can grey out the boards this filter empties.
    @Binding var labelFilter: Set<UUID>
    /// Free text the cards are filtered to, matched against title and body. Owned by the
    /// window for the same reason as `labelFilter`: the sidebar counts answer to it too.
    @Binding var searchQuery: String
    /// Whether archived cards show (dimmed) instead of being hidden. Owned by the window for
    /// the same reason as `labelFilter`/`searchQuery`.
    @Binding var showArchived: Bool

    /// Card density. Unlike the label filter this is remembered across launches and shared by
    /// every board — it hides no cards, so nothing can go missing behind it.
    @AppStorage("board.cardDisplay") private var display: CardDisplay = .full
    /// Everything a step bigger, for showing a board to a room rather than working in it.
    @AppStorage("board.presentation") private var presentation = false

    /// The window's undo manager. Handed to the store on appear so every card edit lands on
    /// the same stack ⌘Z and Edit ▸ Undo already pull from.
    @Environment(\.undoManager) private var undoManager
    /// `UndoManager` is not observable; its checkpoint notification is how a button learns
    /// whether there is anything to undo.
    @State private var canUndo = false

    @State private var drafts: [UUID: String] = [:]
    @State private var nameDraft = ""
    @State private var renameTarget: ColumnRef?
    @State private var deleteTarget: ColumnRef?
    @State private var addColumnTarget: AddColumnScope?
    /// A multi-item paste waiting on the user's call: split it, or keep it as one card.
    @State private var splitTarget: SplitTarget?
    /// What the live drag would do right now — drives the insertion bar, the column highlight
    /// and a card's marching ants, so a drag shows its destination instead of guessing.
    @State private var dropTarget: DropTarget?
    /// Which column a live column-header drag is hovering, and which half of it — drives the
    /// 3pt edge ghost. A separate binding from `dropTarget`: a column drag never shows a card
    /// ghost or the marching ants, so it needs no shared state with those.
    @State private var columnDropTarget: (id: UUID, trailing: Bool)?
    /// The dragged image, decoded once per drag so the hover preview costs nothing per frame.
    @StateObject private var dragLoader = DragImageLoader()
    /// Card row frames, each in its own column's coordinate space. `DropInfo` gives a pointer
    /// position and nothing else — this is what turns it into "over that card" / "in that gap".
    @State private var rowFrames: [UUID: CGRect] = [:]
    /// The card shown big over a blurred board, and how big. Held by id so an edit made while
    /// it is up re-reads from the store.
    @State private var presentedCard: UUID?
    @State private var presentScale: CGFloat = 1.8
    @State private var presentedHeight: CGFloat = 0
    /// Which card the pointer is over: the double-click monitor below gets a point, not a view.
    @State private var hoveredCard: UUID?
    @State private var clickMonitor: Any?
    /// Esc/⌫/⌦/⌘A, installed and removed alongside `clickMonitor`.
    @State private var keyMonitor: Any?
    /// This view's hosting window, so the key monitor can ignore events meant for another
    /// window. Captured once via `BoardWindowAccessor`; a plain `NSWindow?` would work too, but
    /// the accessor is the same seam `NoteWindow` uses for its own window-scoped work.
    @State private var hostWindow: NSWindow?
    /// `visibleOrder` snapshotted on every change. The keyboard monitor's closure is installed
    /// once in `.onAppear` and never rebuilt, so it captures a frozen copy of `board` (a plain
    /// `let`) — reading `visibleOrder` from inside it would silently answer for whichever board
    /// was showing when the monitor was installed. This is `@State`, whose storage stays live
    /// across renders, so the monitor reads through it instead. Named apart from the unrelated
    /// local `order` (column order) inside `columnView(_:)`.
    @State private var selectableOrder: [UUID] = []

    private struct SplitTarget {
        let boardID: UUID
        let columnID: UUID
        let text: String
        let drafts: [CardDraft]
    }

    /// A column plus the board that owns it — `boardID` nil means a global column, which is
    /// exactly the shape `BoardStore`'s column API takes.
    private struct ColumnRef: Identifiable, Equatable {
        let id: UUID
        let boardID: UUID?
        let name: String
        let isDone: Bool
    }

    private enum AddColumnScope: Identifiable {
        case global
        case board(UUID)
        var id: String {
            switch self {
            case .global: return "global"
            case .board(let id): return id.uuidString
            }
        }
    }

    /// A card plus the board that owns it — the all-boards view needs both to move a card
    /// (a move is always within the card's own board) and to badge it.
    private struct CardRef: Identifiable {
        let board: Board
        let card: Card
        var id: UUID { card.id }
    }

    private var renderedColumns: [BoardColumn] {
        board.map { store.columns(for: $0) } ?? store.globalColumns
    }

    /// Every visible card, left-to-right by column and top-to-bottom within it, then "Other" —
    /// what a ⇧-click extends across and what ⌘A selects.
    private var visibleOrder: [UUID] {
        renderedColumns.flatMap { cards(in: $0).map(\.card.id) } + (board == nil ? otherCards.map(\.card.id) : [])
    }

    /// Every card on every board, filters aside — what a selection is pruned against when a
    /// card is deleted out from under it.
    private var allCardIDs: Set<UUID> {
        Set(store.boards.flatMap { $0.cards.map(\.id) })
    }

    var body: some View {
        ZStack {
            board_
            if presentedCard != nil { presentOverlay }
        }
        .animation(.snappy(duration: 0.18), value: presentedCard != nil)
    }

    private var board_: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                GlassSearchField(
                    prompt: String(localized: "Search cards"),
                    text: $searchQuery,
                    identifier: "board.search"
                )
                .frame(maxWidth: 260)
                LabelFilterField(store: store, selected: $labelFilter)
                Button {
                    showArchived.toggle()
                } label: {
                    Image(systemName: showArchived ? "archivebox.fill" : "archivebox")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Show Archived Cards"))
                .accessibilityLabel(Text("Show Archived Cards"))
                .accessibilityValue(showArchived ? "on" : "off")
                .accessibilityIdentifier("board.showArchived")
                displayPicker
                Button {
                    undoManager?.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .disabled(!canUndo)
                .help(String(localized: "Undo"))
                .accessibilityLabel(Text("Undo"))
                .accessibilityIdentifier("board.undo")
                Button {
                    presentation.toggle()
                } label: {
                    Image(systemName: presentation ? "play.rectangle.fill" : "play.rectangle")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Presentation Mode"))
                .accessibilityLabel(Text("Presentation Mode"))
                // Remembered across launches, so a test (or VoiceOver) has to be able to read
                // which way the next click goes.
                .accessibilityValue(presentation ? "on" : "off")
                .accessibilityIdentifier("board.presentation")
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(renderedColumns) { column in
                        columnView(column)
                    }
                    if board == nil, !otherCards.isEmpty {
                        otherColumn
                    }
                    addColumnTile
                }
                .padding(16)
                .contentShape(Rectangle())
                // AppKit only moves first responder to something that accepts it, so a click on a
                // column header, the column background, or a card's padding leaves the card field
                // editing forever — and the face relies on the blur to commit and swap back to text.
                // An outer tap gives those clicks a job. Inner gestures win, so a click on a card's
                // title/notes text (which starts editing) or on a button never reaches this.
                .onTapGesture {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    // A card's own row uses `.simultaneousGesture`, which never blocks this
                    // ancestor gesture — so a plain click on a card would reach here too and
                    // wipe the selection it just made. `hoveredCard` is what tells the two apart.
                    if hoveredCard == nil { selection.clear() }
                }
            }
            .environment(\.cardScale, columnScale)
        }
        .background(BoardWindowAccessor(onWindow: { hostWindow = $0 }))
        .overlay(alignment: .bottom) { selectionBar }
        .onAppear {
            store.undoManager = undoManager
            canUndo = undoManager?.canUndo ?? false
            installDoubleClickMonitor()
            installKeyMonitor()
        }
        .onDisappear {
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            clickMonitor = nil
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
        .onChange(of: visibleOrder, initial: true) { _, new in selectableOrder = new }
        .onChange(of: allCardIDs) { _, ids in selection.prune(keeping: ids) }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerCheckpoint)) { note in
            guard let undoManager, note.object as? UndoManager === undoManager else { return }
            canUndo = undoManager.canUndo
        }
        .sheet(isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            NamePromptSheet(title: "Rename Column", action: "Rename", name: $nameDraft) {
                if let target = renameTarget {
                    try? store.renameColumn(id: target.id, to: nameDraft, boardID: target.boardID)
                }
            }
        }
        .sheet(isPresented: Binding(get: { addColumnTarget != nil }, set: { if !$0 { addColumnTarget = nil } })) {
            NamePromptSheet(title: addColumnTitle, action: "Add", name: $nameDraft) {
                switch addColumnTarget {
                case .global: try? store.addGlobalColumn(name: nameDraft)
                case .board(let id): try? store.addExtraColumn(boardID: id, name: nameDraft)
                case nil: break
                }
            }
        }
        .confirmationDialog(
            "Delete “\(deleteTarget?.name ?? "")”?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Column", role: .destructive) {
                if let target = deleteTarget {
                    try? store.deleteColumn(id: target.id, boardID: target.boardID)
                }
            }
        } message: {
            Text("Its cards move to \(store.globalColumns.first?.name ?? "").")
        }
        .confirmationDialog(
            Text("Add \(splitTarget?.drafts.count ?? 0) cards?"),
            isPresented: Binding(get: { splitTarget != nil }, set: { if !$0 { splitTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Add \(splitTarget?.drafts.count ?? 0) Cards") { commitSplit(asSeparateCards: true) }
            Button("Keep as One Card") { commitSplit(asSeparateCards: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This looks like a list. Each item can become its own card.")
        }
    }

    /// Segmented and ordered least-to-most, so it reads as a density slider rather than three
    /// unrelated modes. Icon-only: it sits on the filter row, and three words there would
    /// out-shout the filter itself.
    private var displayPicker: some View {
        Picker("Card Display", selection: $display) {
            Image(systemName: "rectangle.compress.vertical")
                .accessibilityLabel(Text("Compact"))
                .tag(CardDisplay.compact)
            Image(systemName: "text.alignleft")
                .accessibilityLabel(Text("Titles"))
                .tag(CardDisplay.titles)
            Image(systemName: "rectangle.expand.vertical")
                .accessibilityLabel(Text("Full"))
                .tag(CardDisplay.full)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help(String(localized: "How much of each card to show"))
        .accessibilityIdentifier("board.cardDisplay")
    }

    private var addColumnTitle: LocalizedStringKey {
        if case .board = addColumnTarget { return "New Board Column" }
        return "New Column"
    }

    /// nil `boardID` = a global column; otherwise the column belongs to this board alone.
    private func ref(for column: BoardColumn) -> ColumnRef {
        let owner = board.flatMap { b in b.extraColumns.contains { $0.id == column.id } ? b.id : nil }
        return ColumnRef(id: column.id, boardID: owner, name: column.name, isDone: column.isDone)
    }

    // MARK: - Presenting

    /// How much bigger the whole board draws. The present overlay has a scale of its own —
    /// a card blown up over the board is not the same gesture as a bigger board.
    private var columnScale: CGFloat { presentation ? 1.35 : 1 }

    /// Looked up live rather than captured, so an edit made in the overlay redraws it.
    private var presented: CardRef? {
        guard let id = presentedCard else { return nil }
        for board in store.boards where board.cards.contains(where: { $0.id == id }) {
            guard let card = board.cards.first(where: { $0.id == id }) else { continue }
            return CardRef(board: board, card: card)
        }
        return nil
    }

    /// A double-click on a card is caught with an AppKit monitor rather than a
    /// `TapGesture(count: 2)`: the first click on a title or notes row swaps the label for a
    /// live `NSTextField`, which then takes the second click for its own caret — SwiftUI never
    /// sees a double tap on the row. The event is returned untouched; this only listens.
    private func installDoubleClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard event.clickCount == 2, presentedCard == nil, let id = hoveredCard,
                  !isAttachmentTile(event)
            else { return event }
            // The first click may have opened a field; blur it, or the presented copy and the
            // row underneath both hold a caret.
            NSApp.keyWindow?.makeFirstResponder(nil)
            presentedCard = id
            return event
        }
    }

    /// An attachment tile's own double-click (Quick Look) wins over presenting the card.
    private func isAttachmentTile(_ event: NSEvent) -> Bool {
        DoubleClickCatcherView.catcher(for: event) != nil
    }

    /// Esc clears the selection, ⌫/⌦ deletes it, ⌘A selects every visible card — all gated on
    /// this board's own window being key, no card presented, and the first responder not being
    /// a text field/view, so Delete in a card's title never touches the selection.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === hostWindow, presentedCard == nil,
                  !(event.window?.firstResponder is NSText)
            else { return event }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            switch (event.keyCode, mods) {
            case (53, _) where !selection.ids.isEmpty:
                selection.clear(); return nil
            case (51, []) where !selection.ids.isEmpty, (117, []) where !selection.ids.isEmpty:
                deleteSelected(); return nil
            case (0, .command):
                selection.selectAll(selectableOrder); return nil
            default:
                return event
            }
        }
    }

    /// Bulk delete, grouped so it undoes as one ⌘Z. Snapshots `store.boards` up front —
    /// `deleteCard` mutates the live store as the loop runs, but each `owner` here is already a
    /// value-type copy, so iterating its `cards` is unaffected by the deletes alongside it.
    private func deleteSelected() {
        let ids = selection.ids
        try? store.grouped {
            for owner in store.boards {
                for card in owner.cards where ids.contains(card.id) {
                    try store.deleteCard(boardID: owner.id, cardID: card.id)
                }
            }
        }
        selection.clear()
    }

    /// Whether every currently-selected card is archived — decides the bar's Archive/Unarchive
    /// label and which way it toggles.
    private var allSelectedArchived: Bool {
        let ids = selection.ids
        let selected = store.boards.flatMap(\.cards).filter { ids.contains($0.id) }
        return !selected.isEmpty && selected.allSatisfy { $0.archived != nil }
    }

    private func archiveSelected() {
        let ids = selection.ids
        let archiving = !allSelectedArchived
        try? store.grouped {
            for owner in store.boards {
                let ownIDs = owner.cards.filter { ids.contains($0.id) }.map(\.id)
                if !ownIDs.isEmpty { try store.setArchived(boardID: owner.id, cardIDs: ownIDs, archiving) }
            }
        }
    }

    /// 2+ selected cards, pinned bottom-centre over the board — count, Archive/Unarchive,
    /// Delete, and a close button. Never over the present overlay: this lives on `board_`, not
    /// `body`'s outer `ZStack`.
    @ViewBuilder
    private var selectionBar: some View {
        if selection.ids.count >= 2 {
            HStack(spacing: 14) {
                Text("\(selection.ids.count) Selected")
                    .font(.callout.weight(.medium))
                    .accessibilityIdentifier("board.selection.count")
                Button(allSelectedArchived ? "Unarchive" : "Archive", action: archiveSelected)
                    .accessibilityIdentifier("board.selection.archive")
                Button("Delete", role: .destructive, action: deleteSelected)
                    .accessibilityIdentifier("board.selection.delete")
                Button {
                    selection.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .help(String(localized: "Clear Selection"))
                .accessibilityLabel(Text("Clear Selection"))
                .accessibilityIdentifier("board.selection.clear")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.thinMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
            .padding(.bottom, 16)
        }
    }

    @ViewBuilder
    private var presentOverlay: some View {
        if let ref = presented {
            GeometryReader { geometry in
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .overlay(Color.black.opacity(0.25))
                        .contentShape(Rectangle())
                        .onTapGesture { presentedCard = nil }
                        .accessibilityIdentifier("board.present.backdrop")
                    ScrollView {
                        CardView(
                            store: store,
                            boardID: ref.board.id,
                            card: ref.card,
                            boardBadge: nil,
                            isDone: columnIsDone(ref),
                            isSelected: false,
                            display: .full
                        )
                        .environment(\.cardScale, presentScale)
                        .frame(width: min(280 * presentScale, geometry.size.width - 80))
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { presentedHeight = $0 }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    // A ScrollView takes all the height it is offered, which would pin the
                    // card to the top; sized to its content it sits centred, and only a
                    // card taller than the window scrolls.
                    .frame(height: min(presentedHeight, geometry.size.height - 100))
                }
                // Parked in the corner, not under the card: +/- changes the card's height, and
                // controls that ride on it walk out from under the cursor between clicks.
                .overlay(alignment: .bottomTrailing) { presentControls.padding(20) }
            }
            .transition(.opacity)
        }
    }

    private var presentControls: some View {
        HStack(spacing: 10) {
            Button { presentScale = max(1, presentScale - 0.25) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .keyboardShortcut("-", modifiers: .command)
            .help(String(localized: "Smaller"))
            .accessibilityIdentifier("board.present.smaller")
            Button { presentScale = min(3, presentScale + 0.25) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .keyboardShortcut("=", modifiers: .command)
            .help(String(localized: "Bigger"))
            .accessibilityIdentifier("board.present.larger")
            Button { presentedCard = nil } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .keyboardShortcut(.cancelAction)
            .help(String(localized: "Close"))
            .accessibilityIdentifier("board.present.close")
        }
        .buttonStyle(GlassIconButtonStyle())
    }

    // MARK: - Columns

    private func cards(in column: BoardColumn) -> [CardRef] {
        if let board {
            let live = store.boards.first { $0.id == board.id } ?? board
            return store.cards(in: live, column: column.id)
                .filter { $0.matches(labels: labelFilter, text: searchQuery, showArchived: showArchived) }
                .map { CardRef(board: live, card: $0) }
        }
        return store.boards.flatMap { board in
            store.cards(in: board, column: column.id)
                .filter { $0.matches(labels: labelFilter, text: searchQuery, showArchived: showArchived) }
                .map { CardRef(board: board, card: $0) }
        }
    }

    /// All-boards only: cards parked in board-specific columns, which the shared column set
    /// cannot represent.
    private var otherCards: [CardRef] {
        let globals = Set(store.globalColumns.map(\.id))
        return store.boards.flatMap { board in
            board.cards
                .filter { !globals.contains($0.columnID) && $0.matches(labels: labelFilter, text: searchQuery, showArchived: showArchived) }
                .map { CardRef(board: board, card: $0) }
        }
    }

    private func columnView(_ column: BoardColumn) -> some View {
        let items = cards(in: column)
        let space = "column-\(column.id.uuidString)"
        let order = renderedColumns.map(\.id)
        let index = order.firstIndex(of: column.id)
        let columnWidth = 280 * columnScale
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let emoji = column.emoji { Text(emoji) }
                Text(column.name)
                    .font(.system(size: NSFont.preferredFont(forTextStyle: .headline).pointSize * columnScale,
                                  weight: .semibold))
                    .lineLimit(1)
                    .accessibilityIdentifier("column.name")
                if column.isDone {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                }
                Spacer()
                Text("\(items.count)").font(.caption).foregroundStyle(.secondary)
                Menu {
                    Button("Rename…") { nameDraft = column.name; renameTarget = ref(for: column) }
                    Button(column.isDone ? "Not a Done Column" : "Mark as Done Column") {
                        try? store.setColumnDone(id: column.id, !column.isDone, boardID: ref(for: column).boardID)
                    }
                    Button("Move Left") { moveColumn(column.id, to: (index ?? 0) - 1) }
                        .disabled((index ?? 0) == 0)
                    Button("Move Right") { moveColumn(column.id, to: (index ?? 0) + 1) }
                        .disabled((index ?? 0) == order.count - 1)
                    Button("Archive All Cards") { archiveAll(in: column) }
                        .disabled(!hasUnarchivedCards(in: column))
                    Button("Select All Cards") { selection.selectAll(items.map(\.card.id)) }
                        .disabled(items.isEmpty)
                    Divider()
                    Button("Delete…", role: .destructive) { deleteTarget = ref(for: column) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(String(localized: "Column Actions"))
                .accessibilityIdentifier("column.actions.\(column.id.uuidString)")
            }
            // Dragging the header itself reorders the column — a plain `.onDrag` (not
            // `.draggable`) because the payload is a raw id string under the dedicated
            // `.meatpadColumn` type, not something `Transferable` needs to know about.
            .onDrag {
                NSItemProvider(item: column.id.uuidString as NSString, typeIdentifier: UTType.meatpadColumn.identifier)
            }

            if let board {
                // .plain inside our own container, exactly like GlassSearchField: a bezeled
                // (.roundedBorder / default) field is an NSTextField, and AppKit draws its own
                // focus ring on first responder — SwiftUI's focusEffectDisabled can't reach it.
                HStack(alignment: .top, spacing: 6) {
                    Button {
                        addCard(to: column, in: board)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: NSFont.preferredFont(forTextStyle: .caption1).pointSize * columnScale))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Add card"))
                    // axis: .vertical so a pasted list arrives with its line breaks intact —
                    // a single-line field folds them into spaces and the items are gone.
                    TextField("Add card", text: Binding(
                        get: { drafts[column.id] ?? "" },
                        set: { drafts[column.id] = $0 }
                    ), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: NSFont.preferredFont(forTextStyle: .body).pointSize * columnScale))
                    .lineLimit(1...5)
                    .onSubmit { addCard(to: column, in: board) }
                    .newlineOnModifiedReturn()
                    .accessibilityIdentifier("column.addCard")
                }
                .ringlessField()
            }

            // Only the cards scroll: the header and the add-card field stay put, and a
            // column taller than the window stops overflowing off both ends of it.
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, ref in
                        insertionBar(for: column, at: index)
                        cardRow(ref, in: column, at: index, visible: items, space: space)
                    }
                    insertionBar(for: column, at: items.count)
                    dropGhost(for: column)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: columnWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(MeatPadGlass.violet.opacity(isTargeting(column) ? 0.10 : 0))
        }
        .overlay(alignment: .leading) { columnMoveGhost(column, trailing: false) }
        .overlay(alignment: .trailing) { columnMoveGhost(column, trailing: true) }
        .animation(.snappy(duration: 0.18), value: dropTarget)
        .animation(.snappy(duration: 0.18), value: columnDropTarget?.id)
        // The named space has to sit on the same view as the drop, or `DropInfo.location` and
        // the row frames below are measured against different origins.
        .coordinateSpace(name: space)
        .onDrop(of: [.image, .fileURL, .utf8PlainText, .plainText, .meatpadColumn], delegate: ColumnDropDelegate(
            column: column.id,
            rows: rows(of: items),
            target: $dropTarget,
            loader: dragLoader,
            attach: attach,
            create: newCardBoard.map { owner in { drop in newCard(drop, in: column.id, on: owner) } },
            moveCards: { ids, index in move(ids, to: column.id, visible: items, at: index) },
            columnIndex: index,
            columnOrder: order,
            width: columnWidth,
            columnTarget: $columnDropTarget,
            moveColumn: { id, index in moveColumn(id, to: index) }
        ))
    }

    /// The 3pt accent edge shown on the hovered column, on whichever half the pointer is over —
    /// the only feedback a column drag gives before it drops.
    @ViewBuilder
    private func columnMoveGhost(_ column: BoardColumn, trailing: Bool) -> some View {
        if columnDropTarget?.id == column.id, columnDropTarget?.trailing == trailing {
            Capsule(style: .continuous)
                .fill(MeatPadGlass.violet)
                .frame(width: 3)
                .padding(.vertical, 6)
                .accessibilityIdentifier("column.moveGhost")
        }
    }

    /// Shared by the header drag and the "Move Left"/"Move Right" menu items — both just ask
    /// the store to put the column at a final index, board-scoped in the board view, global in
    /// the all-boards overview.
    private func moveColumn(_ id: UUID, to index: Int) {
        withAnimation(.snappy(duration: 0.22)) {
            try? store.moveColumn(id: id, to: index, onBoard: board?.id)
        }
    }

    /// The tint belongs to the column only when the column itself is the target — an image
    /// over a card is announced by that card's ants instead.
    private func isTargeting(_ column: BoardColumn) -> Bool {
        switch dropTarget {
        case .insert(let id, _), .newCard(let id): return id == column.id
        default: return false
        }
    }

    /// Only rows whose frame has been measured — an unmeasured one would shift every index
    /// after it. In practice a column's `VStack` lays all of its rows out at once.
    private func rows(of items: [CardRef]) -> [BoardDropRow] {
        items.compactMap { ref in rowFrames[ref.id].map { BoardDropRow(id: ref.id, frame: $0) } }
    }

    /// The board a dropped image would make a card on. In the all-boards view there is no
    /// answer unless exactly one board exists, and guessing is worse than refusing.
    private var newCardBoard: UUID? {
        board?.id ?? (store.boards.count == 1 ? store.boards[0].id : nil)
    }

    private func attach(_ cardID: UUID, _ drop: CardDrop) -> Bool {
        guard case .file(let data, let ext, _) = drop,
              let owner = store.boards.first(where: { $0.cards.contains { $0.id == cardID } })
        else { return false }
        return (try? store.addAttachment(boardID: owner.id, cardID: cardID, data: data, ext: ext)) != nil
    }

    private func newCard(_ drop: CardDrop, in columnID: UUID, on boardID: UUID) -> Bool {
        guard case .file(let data, let ext, let name) = drop else { return false }
        let title = BoardDropPlacement.newCardTitle(fileName: name, fallback: String(localized: "File"))
        return (try? store.addCard(boardID: boardID, columnID: columnID, title: title, image: data, ext: ext)) != nil
    }

    /// The gap a dropped card would slot into. Zero height until it is the live target, so
    /// the stack doesn't shift around while nothing is being dragged.
    @ViewBuilder
    private func insertionBar(for column: BoardColumn, at index: Int) -> some View {
        let active = dropTarget == .insert(column: column.id, index: index)
        Capsule(style: .continuous)
            .fill(MeatPadGlass.violet)
            .frame(height: active ? 3 : 0)
            .opacity(active ? 1 : 0)
            .padding(.vertical, active ? 2 : 0)
    }

    /// The card an image dropped on bare column space would become — shown where it would
    /// land, so "nothing happened" stops being the answer to dropping a photo on a column.
    @ViewBuilder
    private func dropGhost(for column: BoardColumn) -> some View {
        if dropTarget == .newCard(column: column.id) {
            HStack(spacing: 8) {
                if let thumbnail = dragLoader.image?.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                Text("New card").font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(height: 64)
            .frame(maxWidth: .infinity, alignment: .leading)
            .marchingAnts(true, cornerRadius: 10)
            .accessibilityIdentifier("column.dropGhost")
        }
    }

    /// Trailing pseudo-column: the only place columns get created, so the header menu stays
    /// about the column you clicked.
    private var addColumnTile: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                nameDraft = ""
                addColumnTarget = .global
            } label: {
                Label("Add Column", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            if let board {
                Button {
                    nameDraft = ""
                    addColumnTarget = .board(board.id)
                } label: {
                    Label("Add Board Column", systemImage: "plus.rectangle.on.rectangle")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "A column only this board shows"))
            }
            Spacer(minLength: 0)
        }
        .frame(width: 200, alignment: .leading)
        .padding(.top, 2)
    }

    private var otherColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Other")
                    .font(.system(size: NSFont.preferredFont(forTextStyle: .headline).pointSize * columnScale,
                                  weight: .semibold))
                Spacer()
                Text("\(otherCards.count)").font(.caption).foregroundStyle(.secondary)
            }
            Text("Cards in board-only columns")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(otherCards) { ref in
                        cardRow(ref, in: nil, space: Self.otherSpace)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: 280 * columnScale, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .coordinateSpace(name: Self.otherSpace)
        // Files onto its cards and nothing else: "Other" is a view of several board-only
        // columns at once, so it has no column a reorder or a new card could mean.
        .onDrop(of: [.image, .fileURL], delegate: ColumnDropDelegate(
            column: nil,
            rows: rows(of: otherCards),
            target: $dropTarget,
            loader: dragLoader,
            attach: attach,
            create: nil,
            moveCards: { _, _ in false },
            // No `.meatpadColumn` in this view's `onDrop` type list above, so the delegate's
            // column-drag branch is never reached here — these are unused placeholders.
            columnIndex: nil,
            columnOrder: [],
            width: 0,
            columnTarget: $columnDropTarget,
            moveColumn: { _, _ in }
        ))
    }

    private static let otherSpace = "column-other"

    // MARK: - Cards

    private func cardRow(_ ref: CardRef, in column: BoardColumn?, at index: Int = 0, visible: [CardRef] = [], space: String) -> some View {
        CardView(
            store: store,
            boardID: ref.board.id,
            card: ref.card,
            boardBadge: board == nil ? ref.board : nil,
            isDone: column?.isDone ?? columnIsDone(ref),
            isSelected: selection.ids.contains(ref.card.id),
            display: display,
            onPresent: { presentedCard = ref.card.id }
        )
        .contentShape(Rectangle())
        // What the double-click monitor reads: a mouse-down carries a window point, and this
        // is the only place that knows which card is under it.
        .onHover { hoveredCard = $0 ? ref.card.id : (hoveredCard == ref.card.id ? nil : hoveredCard) }
        // Simultaneous, not exclusive: a click on the title both selects the card and starts
        // editing — the face's own tap gestures must still fire. Finder rules for the kind:
        // ⌘ toggles, ⇧ extends over the visible order, anything else replaces the selection.
        .simultaneousGesture(TapGesture().onEnded {
            let flags = NSEvent.modifierFlags
            let kind: BoardSelection.Click = flags.contains(.command) ? .toggle : flags.contains(.shift) ? .extend : .plain
            selection.click(ref.card.id, kind, order: visibleOrder)
        })
        .draggable(dragPayload(for: ref)) {
            // A compact chip drags better than a full-card snapshot, and shows what's moving —
            // the card's own title, or a count when the card is part of a 2+ selection.
            Text(dragCount(for: ref) > 1 ? "\(dragCount(for: ref)) Cards" : ref.card.title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(.thinMaterial))
        }
        // The column owns the drop — a card only reports where it is, so the column can tell
        // "over this card" from "in the gap under it".
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: { rowFrames[ref.id] = $0 }
        .onDisappear { rowFrames[ref.id] = nil }
        .marchingAnts(dropTarget == .attach(card: ref.card.id), cornerRadius: 10)
        .overlay(alignment: .topTrailing) { dropBadge(for: ref.card.id) }
    }

    /// The ids a drag started from this card actually carries: the whole selection, in visible
    /// order, when the card is part of a 2+ selection — otherwise just this one card, selection
    /// untouched.
    private func dragIDs(for ref: CardRef) -> [UUID] {
        guard selection.ids.count > 1, selection.ids.contains(ref.card.id) else { return [ref.card.id] }
        return selection.ordered(visibleOrder)
    }
    private func dragPayload(for ref: CardRef) -> String { dragIDs(for: ref).map(\.uuidString).joined(separator: "\n") }
    private func dragCount(for ref: CardRef) -> Int { dragIDs(for: ref).count }

    /// What the card is about to receive. The ants say "this card"; the thumbnail says "this
    /// image" — between them there is nothing left to guess about an image drop.
    @ViewBuilder
    private func dropBadge(for cardID: UUID) -> some View {
        if dropTarget == .attach(card: cardID), let thumbnail = dragLoader.image?.thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.thinMaterial, lineWidth: 1)
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "plus.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, MeatPadGlass.violet)
                        .font(.caption)
                        .offset(x: 3, y: 3)
                }
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                .padding(6)
                .allowsHitTesting(false)
                .accessibilityIdentifier("card.dropPreview")
        }
    }

    private func columnIsDone(_ ref: CardRef) -> Bool {
        store.columns(for: ref.board).first { $0.id == ref.card.columnID }?.isDone ?? false
    }

    /// This board, or every board in the All Boards overview — live values, not the captured `board`.
    private var ownerBoards: [Board] {
        guard let board else { return store.boards }
        return store.boards.filter { $0.id == board.id }
    }

    private func hasUnarchivedCards(in column: BoardColumn) -> Bool {
        ownerBoards.contains { store.cards(in: $0, column: column.id).contains { $0.archived == nil } }
    }

    private func archiveAll(in column: BoardColumn) {
        try? store.grouped {
            for owner in ownerBoards {
                let ids = store.cards(in: owner, column: column.id).filter { $0.archived == nil }.map(\.id)
                if !ids.isEmpty { try store.setArchived(boardID: owner.id, cardIDs: ids, true) }
            }
        }
    }

    /// A card always moves within its own board — in the all-boards view the destination
    /// column is a global one, which every board shares. One or many ids: a multi-card drag
    /// moves the whole batch as a single `store.grouped` block, so one ⌘Z undoes all of it.
    @discardableResult
    private func move(_ ids: [String], to columnID: UUID, visible items: [CardRef], at visibleIndex: Int) -> Bool {
        let moving = ids.compactMap(UUID.init(uuidString:))
        let movingSet = Set(moving)
        var moved = false
        withAnimation(.snappy(duration: 0.22)) {
            try? store.grouped {
                for id in moving {
                    guard let owner = store.boards.first(where: { $0.cards.contains { $0.id == id } }) else { continue }
                    let index = storeIndex(visible: items, at: visibleIndex, column: columnID, board: owner, moving: id, excluding: movingSet)
                    try store.moveCard(id: id, boardID: owner.id, toColumn: columnID, index: index)
                    moved = true
                }
            }
        }
        return moved
    }

    /// A drop index counts the rows the user can SEE. The label and text filters (and, in the
    /// all-boards view, the other boards' cards) hide rows, so the same number means something
    /// else to the store — translate through the card the drop landed above, or the card lands
    /// in the wrong place. Dropping past the last visible row, or above a card from another board,
    /// appends.
    ///
    /// Two cases, because they need different arithmetic:
    /// - The row literally at `visibleIndex` is NOT itself moving: `store.moveCard` already
    ///   removes the card being placed before it numbers the destination's siblings, so handing
    ///   it the anchor's position in the UNFILTERED column (the way a single-card move always
    ///   has) is correct — `moveCard`'s own clamp is what turns "past the last row" into append.
    ///   Filtering `all` here double-removes the mover and lands one slot too early.
    /// - The row literally at `visibleIndex` IS one of the moving cards (dragging part of a
    ///   selection that includes its own neighbor): there is no real anchor there, so skip ahead
    ///   to the next non-moving card and resolve its position with every moving card excluded —
    ///   `all` has to already agree with a column that contains none of them.
    private func storeIndex(visible items: [CardRef], at visibleIndex: Int, column: UUID, board: Board, moving id: UUID, excluding moving: Set<UUID>) -> Int {
        let owner = store.boards.first { $0.id == board.id } ?? board
        guard visibleIndex < items.count else {
            return store.cards(in: owner, column: column).filter { !moving.contains($0.id) }.count
        }
        if !moving.contains(items[visibleIndex].card.id) {
            let anchor = items[visibleIndex].card.id
            let all = store.cards(in: owner, column: column)
            return all.firstIndex { $0.id == anchor } ?? all.count
        }
        let all = store.cards(in: owner, column: column).filter { !moving.contains($0.id) }
        guard let anchor = items[visibleIndex...].first(where: { !moving.contains($0.card.id) })?.card.id
        else { return all.count }
        return all.firstIndex { $0.id == anchor } ?? all.count
    }

    /// One card for typed text, a question for a pasted list. The split is decided here rather
    /// than at paste time: AppKit's field editor is what actually receives ⌘V, so the only
    /// reliable moment to read the text back is when it is submitted.
    private func addCard(to column: BoardColumn, in board: Board) {
        let text = drafts[column.id] ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let items = CardTextSplit.drafts(from: text)
        guard items.count > 1 else {
            if let draft = CardTextSplit.single(from: text) {
                _ = try? store.addCard(boardID: board.id, columnID: column.id, title: draft.title, body: draft.body)
            }
            drafts[column.id] = ""
            return
        }
        splitTarget = SplitTarget(boardID: board.id, columnID: column.id, text: text, drafts: items)
    }

    /// The field is only cleared once the cards exist — cancelling the dialog leaves the paste
    /// where the user put it.
    private func commitSplit(asSeparateCards separate: Bool) {
        guard let target = splitTarget else { return }
        let items = separate ? target.drafts : [CardTextSplit.single(from: target.text)].compactMap { $0 }
        for item in items {
            _ = try? store.addCard(boardID: target.boardID, columnID: target.columnID, title: item.title, body: item.body)
        }
        drafts[target.columnID] = ""
        splitTarget = nil
    }
}

/// Bridges to the hosting NSWindow so the keyboard monitor can ignore key events meant for a
/// different window. Same technique as `NoteWindow`'s own `WindowAccessor` (that one is
/// private to its file, hence a second copy here rather than a shared one).
private struct BoardWindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window { onWindow(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
