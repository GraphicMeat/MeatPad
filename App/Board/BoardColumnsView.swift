import SwiftUI
import MeatPadKit

/// The columns for one board, or for every board at once ("All Boards"). In the all-boards
/// view only the global columns are rendered — a board-specific extra column has no shared
/// counterpart, so its cards collect in a trailing read-only "Other" column instead.
struct BoardColumnsView: View {
    @ObservedObject var store: BoardStore
    /// nil = the All Boards overview.
    let board: Board?
    @Binding var selectedCard: UUID?
    /// Labels the board is filtered to. Empty = show everything. Owned by the window so the
    /// sidebar can grey out the boards this filter empties.
    @Binding var labelFilter: Set<UUID>
    /// Free text the cards are filtered to, matched against title and body. Owned by the
    /// window for the same reason as `labelFilter`: the sidebar counts answer to it too.
    @Binding var searchQuery: String

    /// Card density. Unlike the label filter this is remembered across launches and shared by
    /// every board — it hides no cards, so nothing can go missing behind it.
    @AppStorage("board.cardDisplay") private var display: CardDisplay = .full

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
    /// The dragged image, decoded once per drag so the hover preview costs nothing per frame.
    @StateObject private var dragLoader = DragImageLoader()
    /// Card row frames, each in its own column's coordinate space. `DropInfo` gives a pointer
    /// position and nothing else — this is what turns it into "over that card" / "in that gap".
    @State private var rowFrames: [UUID: CGRect] = [:]

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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                GlassSearchField(
                    prompt: String(localized: "Search cards"),
                    text: $searchQuery,
                    identifier: "board.search"
                )
                .frame(maxWidth: 260)
                LabelFilterField(store: store, selected: $labelFilter)
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
                .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }
            }
        }
        .onAppear { store.undoManager = undoManager; canUndo = undoManager?.canUndo ?? false }
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

    // MARK: - Columns

    private func cards(in column: BoardColumn) -> [CardRef] {
        if let board {
            let live = store.boards.first { $0.id == board.id } ?? board
            return store.cards(in: live, column: column.id)
                .filter { $0.matches(labels: labelFilter, text: searchQuery) }
                .map { CardRef(board: live, card: $0) }
        }
        return store.boards.flatMap { board in
            store.cards(in: board, column: column.id)
                .filter { $0.matches(labels: labelFilter, text: searchQuery) }
                .map { CardRef(board: board, card: $0) }
        }
    }

    /// All-boards only: cards parked in board-specific columns, which the shared column set
    /// cannot represent.
    private var otherCards: [CardRef] {
        let globals = Set(store.globalColumns.map(\.id))
        return store.boards.flatMap { board in
            board.cards
                .filter { !globals.contains($0.columnID) && $0.matches(labels: labelFilter, text: searchQuery) }
                .map { CardRef(board: board, card: $0) }
        }
    }

    private func columnView(_ column: BoardColumn) -> some View {
        let items = cards(in: column)
        let space = "column-\(column.id.uuidString)"
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let emoji = column.emoji { Text(emoji) }
                Text(column.name).font(.headline).lineLimit(1)
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
                    Divider()
                    Button("Delete…", role: .destructive) { deleteTarget = ref(for: column) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(String(localized: "Column Actions"))
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
                            .font(.caption)
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
        .frame(width: 280, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(MeatPadGlass.violet.opacity(isTargeting(column) ? 0.10 : 0))
        }
        .animation(.snappy(duration: 0.18), value: dropTarget)
        // The named space has to sit on the same view as the drop, or `DropInfo.location` and
        // the row frames below are measured against different origins.
        .coordinateSpace(name: space)
        .onDrop(of: [.image, .fileURL, .utf8PlainText, .plainText], delegate: ColumnDropDelegate(
            column: column.id,
            rows: rows(of: items),
            target: $dropTarget,
            loader: dragLoader,
            attach: attach,
            create: newCardBoard.map { owner in { drop in newCard(drop, in: column.id, on: owner) } },
            moveCards: { ids, index in move(ids, to: column.id, visible: items, at: index) }
        ))
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
        guard case .image(let data, let ext, _) = drop,
              let owner = store.boards.first(where: { $0.cards.contains { $0.id == cardID } })
        else { return false }
        return (try? store.addAttachment(boardID: owner.id, cardID: cardID, data: data, ext: ext)) != nil
    }

    private func newCard(_ drop: CardDrop, in columnID: UUID, on boardID: UUID) -> Bool {
        guard case .image(let data, let ext, let name) = drop else { return false }
        let title = BoardDropPlacement.newCardTitle(fileName: name, fallback: String(localized: "Image"))
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
                Text("Other").font(.headline)
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
        .frame(width: 280, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .coordinateSpace(name: Self.otherSpace)
        // Images onto its cards and nothing else: "Other" is a view of several board-only
        // columns at once, so it has no column a reorder or a new card could mean.
        .onDrop(of: [.image], delegate: ColumnDropDelegate(
            column: nil,
            rows: rows(of: otherCards),
            target: $dropTarget,
            loader: dragLoader,
            attach: attach,
            create: nil,
            moveCards: { _, _ in false }
        ))
    }

    private static let otherSpace = "column-other"

    // MARK: - Cards

    private func cardRow(_ ref: CardRef, in column: BoardColumn?, at index: Int = 0, visible: [CardRef] = [], space: String) -> some View {
        CardView(
            store: store,
            boardID: ref.board.id,
            card: ref.card,
            boardBadge: board == nil ? (ref.board.name, store.color(forBoard: ref.board.id)) : nil,
            isDone: column?.isDone ?? columnIsDone(ref),
            isSelected: selectedCard == ref.card.id,
            display: display
        )
        .contentShape(Rectangle())
        // Simultaneous, not exclusive: a click on the title both selects the card and starts
        // editing — the face's own tap gestures must still fire.
        .simultaneousGesture(TapGesture().onEnded { selectedCard = ref.card.id })
        .draggable(ref.card.id.uuidString) {
            // A compact chip drags better than a full-card snapshot, and shows what's moving.
            Text(ref.card.title)
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

    /// A card always moves within its own board — in the all-boards view the destination
    /// column is a global one, which every board shares.
    @discardableResult
    private func move(_ ids: [String], to columnID: UUID, visible items: [CardRef], at visibleIndex: Int) -> Bool {
        var moved = false
        withAnimation(.snappy(duration: 0.22)) {
            for id in ids.compactMap({ UUID(uuidString: $0) }) {
                guard let owner = store.boards.first(where: { $0.cards.contains { $0.id == id } }) else { continue }
                let index = storeIndex(visible: items, at: visibleIndex, column: columnID, board: owner)
                try? store.moveCard(id: id, boardID: owner.id, toColumn: columnID, index: index)
                moved = true
            }
        }
        return moved
    }

    /// A drop index counts the rows the user can SEE. The label and text filters (and, in the
    /// all-boards view, the other boards' cards) hide rows, so the same number means something
    /// else to the store — translate through the card the drop landed above, or the card lands
    /// in the wrong place. Dropping past the last visible row, or above a card from another board,
    /// appends.
    private func storeIndex(visible items: [CardRef], at visibleIndex: Int, column: UUID, board: Board) -> Int {
        let all = store.cards(in: board, column: column)
        guard visibleIndex < items.count else { return all.count }
        let anchor = items[visibleIndex].card.id
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
