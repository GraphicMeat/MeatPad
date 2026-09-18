import Foundation

public enum BoardStoreError: Error, Equatable {
    case boardNotFound(UUID)
    case cardNotFound(UUID)
    case columnNotFound(UUID)
    case labelNotFound(UUID)
    case trashEntryNotFound(UUID)
    case invalidName
    case lastColumn
}

/// One card that deserves a scheduled local notification.
public struct DueReminder: Equatable, Sendable {
    public let cardID: UUID
    public let boardID: UUID
    public let title: String
    public let due: Date

    public init(cardID: UUID, boardID: UUID, title: String, due: Date) {
        self.cardID = cardID
        self.boardID = boardID
        self.title = title
        self.due = due
    }
}

/// Owns the on-disk board collection: `boards.json` (board order + labels) plus one
/// `<board-uuid>.json` per board, cards inline. A sibling of `Notes`, never inside it —
/// kanban state has no business in NoteStore's note-loss-prevention logic.
@MainActor
public final class BoardStore: ObservableObject {
    private let rootURL: URL
    private let defaultColumnNames: (todo: String, inProgress: String, done: String)

    /// Boards in user order (the order they were created in, healed on load).
    @Published public private(set) var boards: [Board] = []

    /// Labels every board's cards can carry, in creation order.
    @Published public private(set) var labels: [CardLabel] = []

    /// Every deleted card/column/board from every board, newest first — one flat list so a
    /// single "Board Trash" view can show and restore across boards, the way `NoteStore`
    /// shows one Trash for every note regardless of folder.
    @Published public private(set) var trash: [TrashEntry] = []

    /// Fixed so a fresh board's Todo/In Progress/Done share an id with every other board's —
    /// that's what lets the All Boards overview pool cards into one "Todo" bucket without a
    /// shared, globally-mutable column list (the bug that used to make deleting a column on
    /// one board delete it from every board).
    private static let todoID = UUID(uuidString: "5D091EAF-B0A5-4000-8000-000000000001")!
    private static let inProgressID = UUID(uuidString: "5D091EAF-B0A5-4000-8000-000000000002")!
    private static let doneID = UUID(uuidString: "5D091EAF-B0A5-4000-8000-000000000003")!

    /// The Todo/In Progress/Done a new board is seeded with, and what the All Boards overview
    /// renders as its own pooling columns — a template, not live state, so renaming or
    /// deleting one board's copy never touches this or any other board's.
    public var defaultColumnTemplate: [BoardColumn] {
        [
            BoardColumn(id: Self.todoID, name: defaultColumnNames.todo, emoji: "📋"),
            BoardColumn(id: Self.inProgressID, name: defaultColumnNames.inProgress, emoji: "🚧"),
            BoardColumn(id: Self.doneID, name: defaultColumnNames.done, isDone: true, emoji: "✅"),
        ]
    }

    /// The window's undo manager, handed in by the board view. Weak because the window owns
    /// it; nil (menu-bar popover, tests) means mutations simply aren't undoable. Every card
    /// mutation below registers its inverse here, so ⌘Z, Edit ▸ Undo and the board's Undo
    /// button all pull from one stack.
    public weak var undoManager: UndoManager?

    /// Card image files, kept under `<root>/Attachments/<cardID>/…`. A board's own
    /// sibling directory, never inside a board's json — see `AttachmentStore`.
    private let attachments: AttachmentStore

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// On-disk shape of `boards.json`. `globalColumns` is legacy: older stores kept one shared
    /// column list here instead of each board owning its columns. Its mere presence in a
    /// decoded index (even `[]`, once every default was deleted) is the one-time migration
    /// signal `init` reads below; a freshly-written index never has the key at all.
    private struct Index: Codable {
        var boardOrder: [UUID]
        var globalColumns: [BoardColumn]?
        /// Optional so an index written before labels existed still decodes.
        var labels: [CardLabel]?
    }

    /// `defaultColumnNames` is injected so the app can seed localized names on first run —
    /// MeatPadKit has no string catalog of its own.
    public init(rootURL: URL,
                defaultColumnNames: (todo: String, inProgress: String, done: String) = ("Todo", "In Progress", "Done")) throws {
        self.rootURL = rootURL
        self.defaultColumnNames = defaultColumnNames
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        attachments = AttachmentStore(rootURL: rootURL.appendingPathComponent("Attachments", isDirectory: true))

        let index = Self.loadIndex(from: rootURL.appendingPathComponent("boards.json"))
        labels = index?.labels ?? []
        boards = Self.loadBoards(from: rootURL, order: index?.boardOrder ?? [])
        trash = Self.loadTrash(from: rootURL.appendingPathComponent("trash.json"))
        // If a board's own file failed to persist below (disk full, permissions, an external
        // volume), the legacy key has to survive on disk so the next launch retries it —
        // there is no backup and no undo for a column mutation, so losing this once is losing
        // it for good.
        var retryLegacyColumns: [BoardColumn]?
        if let legacyGlobalColumns = index?.globalColumns, !migrateLegacyGlobalColumns(legacyGlobalColumns) {
            retryLegacyColumns = legacyGlobalColumns
        }
        healBoardsWithNoColumns()
        // Seeds a fresh install, and re-persists a healed order after a skipped/adopted file.
        try? saveIndex(legacyGlobalColumns: retryLegacyColumns)
    }

    /// A board somehow left with no columns at all (a hand-edited file, or one this store
    /// never seeded) gets the default template — healed once here, at load, rather than
    /// fabricated every time `columns(for:)` is read.
    private func healBoardsWithNoColumns() {
        for idx in boards.indices where boards[idx].extraColumns.isEmpty {
            boards[idx].extraColumns = defaultColumnTemplate
            try? persist(at: idx)
        }
    }

    /// One-time migration off the old shared-column-list model. `legacy` is whatever remained
    /// of that list (possibly missing a default the user had already deleted — deleting one
    /// used to remove it from every board at once, which is the bug this migration retires).
    /// Every board gets its own copy of the surviving defaults, remapped onto the fixed
    /// `defaultColumnTemplate` ids so the All Boards overview keeps pooling them correctly;
    /// any default missing from `legacy` is reseeded fresh (structurally, not with its old
    /// cards back — that link was already overwritten by the old global delete). A column the
    /// user added to the legacy list beyond the three defaults (`addGlobalColumn`) keeps its
    /// own id, copied as-is onto every board. Returns whether every board's file actually
    /// persisted — a board already carrying a template id (a prior, partly-failed attempt)
    /// is left untouched and counts as succeeded, so a retry is idempotent.
    @discardableResult
    private func migrateLegacyGlobalColumns(_ legacyColumns: [BoardColumn]) -> Bool {
        var legacy = legacyColumns
        // One-time heal for a store seeded before columns carried emoji at all: assign by
        // role, exactly like the old in-place heal did — the emoji-keyed match just below
        // can't identify Todo/In Progress/Done without it.
        if legacy.allSatisfy({ $0.emoji == nil }) {
            for i in legacy.indices {
                legacy[i].emoji = legacy[i].isDone ? "✅" : (i == 0 ? "📋" : "🚧")
            }
        }
        var idRemap: [UUID: UUID] = [:]
        var migratedDefaults: [BoardColumn] = []
        for template in defaultColumnTemplate {
            if let match = legacy.first(where: { $0.emoji == template.emoji }) {
                idRemap[match.id] = template.id
                migratedDefaults.append(BoardColumn(id: template.id, name: match.name, isDone: match.isDone, emoji: match.emoji))
            } else {
                migratedDefaults.append(template)
            }
        }
        let extras = legacy.filter { legacyColumn in !migratedDefaults.contains { idRemap[legacyColumn.id] == $0.id } }
        let boardColumns = migratedDefaults + extras
        let templateIDs = Set(defaultColumnTemplate.map(\.id))
        var allPersisted = true
        for idx in boards.indices {
            guard !boards[idx].extraColumns.contains(where: { templateIDs.contains($0.id) }) else { continue }
            for cardIdx in boards[idx].cards.indices {
                if let newID = idRemap[boards[idx].cards[cardIdx].columnID] {
                    boards[idx].cards[cardIdx].columnID = newID
                }
            }
            boards[idx].extraColumns = boardColumns + boards[idx].extraColumns
            do { try persist(at: idx) } catch { allPersisted = false }
        }
        return allPersisted
    }

    // MARK: - Boards

    @discardableResult
    public func createBoard(name: String) throws -> Board {
        let board = Board(name: try validated(name), extraColumns: defaultColumnTemplate)
        try write(board)
        boards.append(board)
        try saveIndex()
        return board
    }

    public func renameBoard(id: UUID, to name: String) throws {
        let idx = try boardIndex(id)
        boards[idx].name = try validated(name)
        try persist(at: idx)
    }

    /// Trashes the whole board — cards, columns, icon image and all — rather than deleting it.
    /// Every attachment file (the board's own icon, every card's) is left on disk exactly like
    /// a trashed card's; only purging the trash entry removes them.
    public func deleteBoard(id: UUID) throws {
        let idx = try boardIndex(id)
        let board = boards[idx]
        try appendToTrash(TrashEntry(kind: .board, boardID: id, boardName: board.name, board: board))
        let url = boardURL(id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        boards.removeAll { $0.id == id }
        try saveIndex()
    }

    // MARK: - Board icon

    /// A board's look is one thing, so an emoji drops whatever image it had — and the file
    /// with it, because nothing would ever reference it again.
    public func setBoardIcon(id: UUID, emoji: String) throws {
        let idx = try boardIndex(id)
        let trimmed = try validated(emoji)
        dropBoardImage(at: idx)
        boards[idx].icon = trimmed
        try persist(at: idx)
    }

    /// The same rule from the other side: an image drops the emoji, and the image it replaces.
    /// The write comes first — a rejected extension must leave the board exactly as it was.
    public func setBoardImage(id: UUID, data: Data, ext: String) throws {
        let idx = try boardIndex(id)
        let name = try attachments.add(data, ext: ext, to: id)
        dropBoardImage(at: idx)
        boards[idx].image = name
        boards[idx].icon = nil
        try persist(at: idx)
    }

    /// Back to the default glyph: no emoji, no image, no orphaned file.
    public func clearBoardIcon(id: UUID) throws {
        let idx = try boardIndex(id)
        dropBoardImage(at: idx)
        boards[idx].icon = nil
        try persist(at: idx)
    }

    /// nil for a board with no image, and for an id that isn't a board — the sidebar asks
    /// this per row and has nothing sensible to draw in either case.
    public func boardImageURL(_ id: UUID) -> URL? {
        guard let board = boards.first(where: { $0.id == id }), let name = board.image else { return nil }
        return attachments.url(name, for: id)
    }

    /// Forgets the board's image and deletes its file. Best-effort on the file: a board that
    /// still points at a file it cannot delete is worse than a stray byte on disk.
    private func dropBoardImage(at idx: Int) {
        if let name = boards[idx].image { try? attachments.remove(name, from: boards[idx].id) }
        boards[idx].image = nil
    }

    // MARK: - Columns (composition)

    /// Rendered order for a board: its own columns, in `columnOrder` if it has one.
    public func columns(for board: Board) -> [BoardColumn] {
        let all = board.extraColumns
        guard let order = board.columnOrder else { return all }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return all.enumerated()
            .sorted { (rank[$0.element.id] ?? order.count + $0.offset, $0.offset)
                    < (rank[$1.element.id] ?? order.count + $1.offset, $1.offset) }
            .map(\.element)
    }

    /// A column's cards, already in display order — `board.cards` order IS column order.
    public func cards(in board: Board, column: UUID) -> [Card] {
        board.cards.filter { $0.columnID == column }
    }

    // MARK: - Cards

    /// An explicit begin/end group is what lets a unit test register at all — `groupsByEvent
    /// = false` with no run loop means an ungrouped `registerUndo` call would assert. It also
    /// gives the test the same one-step-per-edit view the app gets from event grouping; in
    /// the app these groups nest inside the run loop event's own group, so several mutations
    /// in one pass (e.g. a multi-card drag) undo together as one step — intended.
    ///
    /// ponytail: every inverse below runs through `try?`, so a stale step (its board or
    /// column deleted since) silently no-ops instead of erroring. Board/column/label
    /// mutations aren't undoable yet at all — only cards and their attachments are.
    private func registerUndo(_ inverse: @escaping @MainActor (BoardStore) -> Void) {
        guard let undoManager else { return }
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { inverse(store) }
        }
        undoManager.endUndoGrouping()
    }

    @discardableResult
    public func addCard(boardID: UUID, columnID: UUID, title: String, body: String? = nil) throws -> Card {
        let idx = try boardIndex(boardID)
        guard columns(for: boards[idx]).contains(where: { $0.id == columnID }) else {
            throw BoardStoreError.columnNotFound(columnID)
        }
        let card = Card(title: try validated(title), body: body, columnID: columnID)
        boards[idx].cards.append(card)
        try persist(at: idx)
        registerUndo { try? $0.deleteCard(boardID: boardID, cardID: card.id) }
        return card
    }

    /// A card made out of a dropped image. One outer undo group around both mutations: the
    /// user made one gesture, so ⌘Z must take the card and its file away together instead of
    /// leaving an empty card behind.
    @discardableResult
    public func addCard(boardID: UUID, columnID: UUID, title: String, image data: Data, ext: String) throws -> Card {
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }
        let card = try addCard(boardID: boardID, columnID: columnID, title: title)
        try addAttachment(boardID: boardID, cardID: card.id, data: data, ext: ext)
        return card
    }

    /// Replaces a card wholesale and stamps `modified`. Callers edit a copy and hand it back.
    public func updateCard(boardID: UUID, card: Card) throws {
        let idx = try boardIndex(boardID)
        guard let cardIdx = boards[idx].cards.firstIndex(where: { $0.id == card.id }) else {
            throw BoardStoreError.cardNotFound(card.id)
        }
        let previous = boards[idx].cards[cardIdx]
        var updated = card
        updated.title = try validated(card.title)
        updated.modified = Date()
        boards[idx].cards[cardIdx] = updated
        try persist(at: idx)
        registerUndo { try? $0.updateCard(boardID: boardID, card: previous) }
    }

    /// Trashes the card rather than deleting it outright: it moves to `trash`, restorable from
    /// the Board Trash view or by ⌘Z, either of which lands on the same `uncard` below. Its
    /// attachment files are left exactly where they are — `AttachmentStore` doesn't know or
    /// care whether a card is live or trashed, only purging a trash entry removes them.
    public func deleteCard(boardID: UUID, cardID: UUID) throws {
        let idx = try boardIndex(boardID)
        guard let cardIdx = boards[idx].cards.firstIndex(where: { $0.id == cardID }) else {
            throw BoardStoreError.cardNotFound(cardID)
        }
        let card = boards[idx].cards[cardIdx]
        try appendToTrash(TrashEntry(kind: .card, boardID: boardID, boardName: boards[idx].name, card: card))
        boards[idx].cards.remove(at: cardIdx)
        try persist(at: idx)
        registerUndo { $0.uncard(card, boardID: boardID, at: cardIdx) }
    }

    /// The inverse of `deleteCard`: the card goes back where it was in the flat array, which is
    /// also where it was in its column, and its trash entry disappears. Registers the delete
    /// as its own inverse.
    private func uncard(_ card: Card, boardID: UUID, at index: Int) {
        guard let idx = try? boardIndex(boardID) else { return }
        boards[idx].cards.insert(card, at: min(index, boards[idx].cards.count))
        try? persist(at: idx)
        trash.removeAll { $0.kind == .card && $0.card?.id == card.id }
        try? saveTrash()
        registerUndo { try? $0.deleteCard(boardID: boardID, cardID: card.id) }
    }

    /// Moves a card to `index` within `toColumn` (clamped). The position is expressed in the
    /// destination column's own coordinates, which is all a drop target knows.
    public func moveCard(id: UUID, boardID: UUID, toColumn: UUID, index: Int) throws {
        let idx = try boardIndex(boardID)
        guard columns(for: boards[idx]).contains(where: { $0.id == toColumn }) else {
            throw BoardStoreError.columnNotFound(toColumn)
        }
        guard let cardIdx = boards[idx].cards.firstIndex(where: { $0.id == id }) else {
            throw BoardStoreError.cardNotFound(id)
        }
        var card = boards[idx].cards.remove(at: cardIdx)
        let fromColumn = card.columnID
        // Column-local position before the move — what the inverse `moveCard` needs. The
        // guarantee this buys is column-local too: the inverse restores each column's order
        // exactly, not the flat `cards` array's cross-column interleaving. E.g. flat
        // [A(todo), X(todo), B(doing), C(todo)] → move X → undo yields [A, B, X, C]; every
        // `cards(in:column:)` result is identical to before, which is all the UI ever reads.
        let fromIndex = boards[idx].cards[..<cardIdx].filter { $0.columnID == fromColumn }.count
        card.columnID = toColumn

        // Translate the column-local index into an index in the flat `cards` array.
        let siblings = boards[idx].cards.enumerated().filter { $0.element.columnID == toColumn }
        let clamped = max(0, min(index, siblings.count))
        let insertAt = clamped < siblings.count ? siblings[clamped].offset : boards[idx].cards.count
        boards[idx].cards.insert(card, at: insertAt)
        try persist(at: idx)
        registerUndo { try? $0.moveCard(id: id, boardID: boardID, toColumn: fromColumn, index: fromIndex) }
    }

    /// Cards already in the requested state are left alone, so re-archiving keeps the first date.
    public func setArchived(boardID: UUID, cardIDs: [UUID], _ archived: Bool, now: Date = Date()) throws {
        let idx = try boardIndex(boardID)
        let wanted = Set(cardIDs)
        var previous: [UUID: Date?] = [:]
        for i in boards[idx].cards.indices where wanted.contains(boards[idx].cards[i].id) {
            guard (boards[idx].cards[i].archived != nil) != archived else { continue }
            previous[boards[idx].cards[i].id] = boards[idx].cards[i].archived
            boards[idx].cards[i].archived = archived ? now : nil
        }
        guard !previous.isEmpty else { return }
        try persist(at: idx)
        registerUndo { store in
            guard let i = try? store.boardIndex(boardID) else { return }
            for c in store.boards[i].cards.indices {
                if let old = previous[store.boards[i].cards[c].id] { store.boards[i].cards[c].archived = old }
            }
            try? store.persist(at: i)
            store.registerUndo { try? $0.setArchived(boardID: boardID, cardIDs: Array(previous.keys), archived, now: now) }
        }
    }

    /// Several card mutations that should undo as one ⌘Z (bulk delete/archive/move).
    public func grouped(_ body: () throws -> Void) rethrows {
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }
        try body()
    }

    // MARK: - Attachments

    @discardableResult
    public func addAttachment(boardID: UUID, cardID: UUID, data: Data, ext: String) throws -> String {
        let idx = try boardIndex(boardID)
        guard let cardIdx = boards[idx].cards.firstIndex(where: { $0.id == cardID }) else {
            throw BoardStoreError.cardNotFound(cardID)
        }
        let name = try attachments.add(data, ext: ext, to: cardID)
        boards[idx].cards[cardIdx].attachments = (boards[idx].cards[cardIdx].attachments ?? []) + [name]
        boards[idx].cards[cardIdx].modified = Date()
        try persist(at: idx)
        registerUndo { try? $0.removeAttachment(boardID: boardID, cardID: cardID, name: name) }
        return name
    }

    /// The bytes ride along in the undo closure: a removed image has nowhere else to live.
    public func removeAttachment(boardID: UUID, cardID: UUID, name: String) throws {
        let idx = try boardIndex(boardID)
        guard let cardIdx = boards[idx].cards.firstIndex(where: { $0.id == cardID }),
              let position = boards[idx].cards[cardIdx].attachments?.firstIndex(of: name)
        else { throw BoardStoreError.cardNotFound(cardID) }
        let data = attachments.data(name, for: cardID)
        try attachments.remove(name, from: cardID)
        var names = boards[idx].cards[cardIdx].attachments ?? []
        names.remove(at: position)
        boards[idx].cards[cardIdx].attachments = names.isEmpty ? nil : names
        try persist(at: idx)
        registerUndo { store in
            if let data { try? store.attachments.write(data, name: name, to: cardID) }
            guard let idx = try? store.boardIndex(boardID),
                  let cardIdx = store.boards[idx].cards.firstIndex(where: { $0.id == cardID }) else { return }
            var names = store.boards[idx].cards[cardIdx].attachments ?? []
            names.insert(name, at: min(position, names.count))
            store.boards[idx].cards[cardIdx].attachments = names
            try? store.persist(at: idx)
            store.registerUndo { try? $0.removeAttachment(boardID: boardID, cardID: cardID, name: name) }
        }
    }

    public func attachmentURL(cardID: UUID, name: String) -> URL {
        attachments.url(name, for: cardID)
    }

    // MARK: - Column editing

    public func addExtraColumn(boardID: UUID, name: String) throws {
        let idx = try boardIndex(boardID)
        boards[idx].extraColumns.append(BoardColumn(name: try validated(name)))
        try persist(at: idx)
    }

    /// `index` is the column's final position within that board's own rendered order.
    public func moveColumn(id: UUID, to index: Int, onBoard boardID: UUID) throws {
        let idx = try boardIndex(boardID)
        var ids = columns(for: boards[idx]).map(\.id)
        guard let from = ids.firstIndex(of: id) else { throw BoardStoreError.columnNotFound(id) }
        ids.remove(at: from)
        ids.insert(id, at: max(0, min(index, ids.count)))
        boards[idx].columnOrder = ids
        try persist(at: idx)
    }

    public func renameColumn(id: UUID, to name: String, boardID: UUID) throws {
        let trimmed = try validated(name)
        try mutateColumn(id: id, boardID: boardID) { $0.name = trimmed }
    }

    public func setColumnDone(id: UUID, _ isDone: Bool, boardID: UUID) throws {
        try mutateColumn(id: id, boardID: boardID) { $0.isDone = isDone }
    }

    /// Deleting a column never deletes work: its cards move to that board's own first
    /// remaining column, visibly, right away — and the column plus a snapshot of exactly which
    /// cards were in it goes to `trash`, so restoring can move those same cards back rather
    /// than leaving a restored column empty. That last column on a board is the fallback, so
    /// it cannot itself be removed — a board always shows at least one column.
    public func deleteColumn(id: UUID, boardID: UUID) throws {
        let idx = try boardIndex(boardID)
        guard let colIdx = boards[idx].extraColumns.firstIndex(where: { $0.id == id }) else {
            throw BoardStoreError.columnNotFound(id)
        }
        guard boards[idx].extraColumns.count > 1 else { throw BoardStoreError.lastColumn }
        let column = boards[idx].extraColumns[colIdx]
        let cardsInColumn = boards[idx].cards.filter { $0.columnID == id }
        try appendToTrash(TrashEntry(kind: .column, boardID: boardID, boardName: boards[idx].name,
                                      column: column, columnCards: cardsInColumn))
        boards[idx].extraColumns.remove(at: colIdx)
        reassignCards(from: id, boardIndex: idx)
        try persist(at: idx)
    }

    private func reassignCards(from columnID: UUID, boardIndex idx: Int) {
        guard let fallback = boards[idx].extraColumns.first?.id else { return }
        for cardIdx in boards[idx].cards.indices where boards[idx].cards[cardIdx].columnID == columnID {
            boards[idx].cards[cardIdx].columnID = fallback
        }
    }

    private func mutateColumn(id: UUID, boardID: UUID, _ change: (inout BoardColumn) -> Void) throws {
        let idx = try boardIndex(boardID)
        guard let colIdx = boards[idx].extraColumns.firstIndex(where: { $0.id == id }) else {
            throw BoardStoreError.columnNotFound(id)
        }
        change(&boards[idx].extraColumns[colIdx])
        try persist(at: idx)
    }

    // MARK: - Trash

    /// Puts a trashed card, column or board back. A card whose stored column no longer exists
    /// on the board (that column was itself deleted after this card was trashed) lands in the
    /// board's first column instead of carrying a dangling id. Returns `false` rather than
    /// throwing when the origin board is gone too (a `.board` entry restores regardless — it
    /// has no "origin" beyond itself) — the trash row disables Restore on that, this is the
    /// last-resort guard if it's pressed anyway.
    @discardableResult
    public func restoreFromTrash(id: UUID) throws -> Bool {
        guard let entryIdx = trash.firstIndex(where: { $0.id == id }) else {
            throw BoardStoreError.trashEntryNotFound(id)
        }
        let entry = trash[entryIdx]
        // Decide first, without changing anything: `false` here must mean nothing happened,
        // not "removed from trash but the board never got it back."
        switch entry.kind {
        case .card:
            guard entry.card != nil, boards.contains(where: { $0.id == entry.boardID }) else { return false }
        case .column:
            guard entry.column != nil, boards.contains(where: { $0.id == entry.boardID }) else { return false }
        case .board:
            guard let board = entry.board, !boards.contains(where: { $0.id == board.id }) else { return false }
        }
        // The entry's removal is what has to survive a crash between here and the mutation
        // below — restoring twice (a duplicate card) is worse than a retry finding it still
        // in trash.
        try removeFromTrash(id: id)
        switch entry.kind {
        case .card:
            guard var card = entry.card, let idx = try? boardIndex(entry.boardID) else { return false }
            if !boards[idx].extraColumns.contains(where: { $0.id == card.columnID }) {
                card.columnID = boards[idx].extraColumns.first?.id ?? card.columnID
            }
            boards[idx].cards.append(card)
            try persist(at: idx)
        case .column:
            guard let column = entry.column, let idx = try? boardIndex(entry.boardID) else { return false }
            boards[idx].extraColumns.append(column)
            let restoredCardIDs = Set((entry.columnCards ?? []).map(\.id))
            for cardIdx in boards[idx].cards.indices where restoredCardIDs.contains(boards[idx].cards[cardIdx].id) {
                boards[idx].cards[cardIdx].columnID = column.id
            }
            try persist(at: idx)
        case .board:
            guard let board = entry.board else { return false }
            boards.append(board)
            try write(board)
            try saveIndex()
        }
        return true
    }

    /// Forgets one trash entry for good. The entry's removal persists before its attachment
    /// files (if any) are cleaned up — a failed cleanup should leave nothing pointing at the
    /// missing files, not an entry that still claims to hold them.
    public func purgeTrashEntry(id: UUID) throws {
        guard let entryIdx = trash.firstIndex(where: { $0.id == id }) else {
            throw BoardStoreError.trashEntryNotFound(id)
        }
        let entry = trash[entryIdx]
        try removeFromTrash(id: id)
        purgeAttachments(of: entry)
    }

    public func emptyTrash() throws {
        let entries = trash
        trash = []
        try saveTrash()
        for entry in entries { purgeAttachments(of: entry) }
    }

    /// A trashed card's or board's files are never touched until this point. A trashed
    /// *column*'s cards are the one exception: `deleteColumn` reassigns them to the fallback
    /// column and they stay live on the board, so their files are never this function's to
    /// remove — only the column's own definition (name/emoji/id) was ever trashed.
    private func purgeAttachments(of entry: TrashEntry) {
        switch entry.kind {
        case .card:
            if let card = entry.card { try? attachments.removeAll(for: card.id) }
        case .column:
            break
        case .board:
            guard let board = entry.board else { return }
            for card in board.cards { try? attachments.removeAll(for: card.id) }
            try? attachments.removeAll(for: board.id)
        }
    }

    // MARK: - Labels

    /// The colour is proposed, not demanded: pass one to honour the user's pick, or leave it
    /// off for the least-used palette entry, so a label made in a hurry is still distinct.
    @discardableResult
    public func createLabel(name: String, color: RGBAColor? = nil) throws -> CardLabel {
        let label = CardLabel(name: try validated(name), color: color ?? nextLabelColor())
        labels.append(label)
        try saveIndex()
        return label
    }

    /// The colour a brand-new label would be given right now — the swatch a "new label" form
    /// starts on, so creating without touching the colours matches what the store would pick.
    public var suggestedLabelColor: RGBAColor { nextLabelColor() }

    /// A board's own colour, so the All Boards overview can tell four boards apart at a
    /// glance. Taken from the palette by position, not by hashing the id: position cannot
    /// collide, and a hash sooner or later hands two boards the same colour.
    public func color(forBoard id: UUID) -> RGBAColor {
        let index = boards.firstIndex { $0.id == id } ?? 0
        return CardLabel.palette[index % CardLabel.palette.count]
    }

    public func renameLabel(id: UUID, to name: String) throws {
        let trimmed = try validated(name)
        try mutateLabel(id) { $0.name = trimmed }
    }

    public func setLabelColor(id: UUID, _ color: RGBAColor) throws {
        try mutateLabel(id) { $0.color = color }
    }

    /// Deleting a label strips it off every card that carried it — a dangling id renders as
    /// a chip with no name and no way to get rid of it.
    public func deleteLabel(id: UUID) throws {
        guard labels.contains(where: { $0.id == id }) else { throw BoardStoreError.labelNotFound(id) }
        labels.removeAll { $0.id == id }
        try saveIndex()
        for idx in boards.indices where boards[idx].cards.contains(where: { $0.labelIDs?.contains(id) ?? false }) {
            for cardIdx in boards[idx].cards.indices {
                guard let ids = boards[idx].cards[cardIdx].labelIDs, ids.contains(id) else { continue }
                boards[idx].cards[cardIdx].labelIDs = ids.filter { $0 != id }
            }
            try persist(at: idx)
        }
    }

    private func mutateLabel(_ id: UUID, _ change: (inout CardLabel) -> Void) throws {
        guard let idx = labels.firstIndex(where: { $0.id == id }) else { throw BoardStoreError.labelNotFound(id) }
        change(&labels[idx])
        try saveIndex()
    }

    /// `min(by:)` keeps the first of equal elements, so ties break on palette order and new
    /// labels walk the palette top to bottom instead of jumping around it.
    private func nextLabelColor() -> RGBAColor {
        var used: [RGBAColor: Int] = [:]
        for label in labels { used[label.color, default: 0] += 1 }
        return CardLabel.palette.min { (used[$0] ?? 0) < (used[$1] ?? 0) } ?? CardLabel.palette[0]
    }

    // MARK: - Note link

    /// The derived half of the note↔card link. `card.noteID` is the only stored pointer, so
    /// this can never disagree with it — no cleanup needed when either side is trashed.
    public func card(forNote noteID: UUID) -> (board: Board, card: Card)? {
        for board in boards {
            if let card = board.cards.first(where: { $0.noteID == noteID }) { return (board, card) }
        }
        return nil
    }

    // MARK: - Due reminders

    /// Every card that should hold a pending notification: dated, still in the future, and
    /// not sitting in a done column. Pure, so the App-layer notifier is a dumb replayer and
    /// the scheduling *decision* stays unit-testable.
    public func pendingDueReminders(now: Date = Date()) -> [DueReminder] {
        boards.flatMap { board -> [DueReminder] in
            let doneColumns = Set(columns(for: board).filter(\.isDone).map(\.id))
            return board.cards.compactMap { card in
                guard let due = card.due, due > now, card.archived == nil, !doneColumns.contains(card.columnID) else { return nil }
                return DueReminder(cardID: card.id, boardID: board.id, title: card.title, due: due)
            }
        }
    }

    // MARK: - Storage

    /// `<storage base>/Boards`, resolved through the same override key NoteStore reads so
    /// every store agrees on one root.
    public static func defaultRoot(defaults: UserDefaults = .standard) -> URL {
        NoteStore.defaultRoot(defaults: defaults)
            .deletingLastPathComponent()
            .appendingPathComponent("Boards", isDirectory: true)
    }

    private var indexURL: URL {
        rootURL.appendingPathComponent("boards.json")
    }

    private var trashURL: URL {
        rootURL.appendingPathComponent("trash.json")
    }

    private func boardURL(_ id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private func boardIndex(_ id: UUID) throws -> Int {
        guard let idx = boards.firstIndex(where: { $0.id == id }) else { throw BoardStoreError.boardNotFound(id) }
        return idx
    }

    /// Trims and rejects empty — the one name rule shared by boards, columns, and cards.
    private func validated(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BoardStoreError.invalidName }
        return trimmed
    }

    private static func loadIndex(from url: URL) -> Index? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(Index.self, from: data)
    }

    /// Missing or corrupt reads as empty trash rather than failing the whole store — the same
    /// self-healing stance `loadBoards` takes on a bad board file.
    private static func loadTrash(from url: URL) -> [TrashEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder.decode([TrashEntry].self, from: data)) ?? []
    }

    /// Self-healing: a corrupt board file is skipped, an id in the order with no file on
    /// disk is dropped, and a board file missing from the order is adopted at the end.
    private static func loadBoards(from rootURL: URL, order: [UUID]) -> [Board] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []
        var byID: [UUID: Board] = [:]
        for url in urls where url.pathExtension == "json" && url.lastPathComponent != "boards.json" {
            guard let data = try? Data(contentsOf: url),
                  let board = try? decoder.decode(Board.self, from: data),
                  board.id.uuidString == url.deletingPathExtension().lastPathComponent else { continue }
            byID[board.id] = board
        }
        var ordered = order.compactMap { byID[$0] }
        let known = Set(ordered.map(\.id))
        ordered.append(contentsOf: byID.values.filter { !known.contains($0.id) }.sorted { $0.name < $1.name })
        return ordered
    }

    /// `legacyGlobalColumns` is only ever non-nil right after `init` retries an incomplete
    /// migration — every other call site keeps the default `nil`, which drops the key.
    private func saveIndex(legacyGlobalColumns: [BoardColumn]? = nil) throws {
        let index = Index(boardOrder: boards.map(\.id), globalColumns: legacyGlobalColumns, labels: labels)
        try Self.encoder.encode(index).write(to: indexURL, options: .atomic)
    }

    private func saveTrash() throws {
        try Self.encoder.encode(trash).write(to: trashURL, options: .atomic)
    }

    /// Records `entry` to disk *before* it becomes visible in memory (and before the caller's
    /// destructive mutation runs): if the write fails, `trash` never changes and the caller's
    /// `try` stops the delete from happening at all — the recovery record has to exist before
    /// the thing it recovers can be destroyed, not after.
    private func appendToTrash(_ entry: TrashEntry) throws {
        var updated = trash
        updated.insert(entry, at: 0)
        try Self.encoder.encode(updated).write(to: trashURL, options: .atomic)
        trash = updated
    }

    /// The restore/purge-side mirror of `appendToTrash`: persists the entry's removal before
    /// the caller does anything with what it held, so a failed write leaves the entry in
    /// trash (annoying) rather than the entry gone and its effect never applied (data lost).
    private func removeFromTrash(id: UUID) throws {
        var updated = trash
        updated.removeAll { $0.id == id }
        try Self.encoder.encode(updated).write(to: trashURL, options: .atomic)
        trash = updated
    }

    private func write(_ board: Board) throws {
        try Self.encoder.encode(board).write(to: boardURL(board.id), options: .atomic)
    }

    /// Persists the board at `index` after an in-memory mutation.
    private func persist(at index: Int) throws {
        try write(boards[index])
    }
}
