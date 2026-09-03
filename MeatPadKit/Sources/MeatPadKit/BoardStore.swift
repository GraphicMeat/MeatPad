import Foundation

public enum BoardStoreError: Error, Equatable {
    case boardNotFound(UUID)
    case cardNotFound(UUID)
    case columnNotFound(UUID)
    case labelNotFound(UUID)
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

/// Owns the on-disk board collection: `boards.json` (board order + global columns) plus one
/// `<board-uuid>.json` per board, cards inline. A sibling of `Notes`, never inside it —
/// kanban state has no business in NoteStore's note-loss-prevention logic.
@MainActor
public final class BoardStore: ObservableObject {
    private let rootURL: URL

    /// Boards in user order (the order they were created in, healed on load).
    @Published public private(set) var boards: [Board] = []

    /// Columns every board shows, before its own extras.
    @Published public private(set) var globalColumns: [BoardColumn] = []

    /// Labels every board's cards can carry, in creation order.
    @Published public private(set) var labels: [CardLabel] = []

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

    /// On-disk shape of `boards.json`.
    private struct Index: Codable {
        var boardOrder: [UUID]
        var globalColumns: [BoardColumn]
        /// Optional so an index written before labels existed still decodes.
        var labels: [CardLabel]?
    }

    /// `defaultColumnNames` is injected so the app can seed localized names on first run —
    /// MeatPadKit has no string catalog of its own.
    public init(rootURL: URL,
                defaultColumnNames: (todo: String, inProgress: String, done: String) = ("Todo", "In Progress", "Done")) throws {
        self.rootURL = rootURL
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        attachments = AttachmentStore(rootURL: rootURL.appendingPathComponent("Attachments", isDirectory: true))

        let index = Self.loadIndex(from: rootURL.appendingPathComponent("boards.json"))
        globalColumns = index?.globalColumns ?? [
            BoardColumn(name: defaultColumnNames.todo, emoji: "📋"),
            BoardColumn(name: defaultColumnNames.inProgress, emoji: "🚧"),
            BoardColumn(name: defaultColumnNames.done, isDone: true, emoji: "✅"),
        ]
        // One-time heal for a store seeded before columns carried emoji: assign by role, and
        // never again — any emoji present means the user's choices are already in play.
        if globalColumns.allSatisfy({ $0.emoji == nil }) {
            for i in globalColumns.indices {
                globalColumns[i].emoji = globalColumns[i].isDone ? "✅" : (i == 0 ? "📋" : "🚧")
            }
        }
        labels = index?.labels ?? []
        boards = Self.loadBoards(from: rootURL, order: index?.boardOrder ?? [])
        // Seeds a fresh install, and re-persists a healed order after a skipped/adopted file.
        try? saveIndex()
    }

    // MARK: - Boards

    @discardableResult
    public func createBoard(name: String) throws -> Board {
        let board = Board(name: try validated(name))
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

    public func deleteBoard(id: UUID) throws {
        let idx = try boardIndex(id)
        for card in boards[idx].cards { try? attachments.removeAll(for: card.id) }
        let url = boardURL(id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        boards.removeAll { $0.id == id }
        try saveIndex()
    }

    // MARK: - Columns (composition)

    /// Rendered order for a board: the global columns first, then that board's extras.
    public func columns(for board: Board) -> [BoardColumn] {
        globalColumns + board.extraColumns
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

    public func deleteCard(boardID: UUID, cardID: UUID) throws {
        let idx = try boardIndex(boardID)
        guard let cardIdx = boards[idx].cards.firstIndex(where: { $0.id == cardID }) else {
            throw BoardStoreError.cardNotFound(cardID)
        }
        let card = boards[idx].cards[cardIdx]
        // Snapshotted before the files are gone — the undo has nowhere else to read them from.
        let files: [(String, Data)] = (card.attachments ?? []).compactMap { name in
            attachments.data(name, for: cardID).map { (name, $0) }
        }
        boards[idx].cards.remove(at: cardIdx)
        try persist(at: idx)
        // Best-effort: the card is already gone from the board, and a failed cleanup here
        // (permissions, a Quick Look handle on one of the files, an external volume) must not
        // cost the undo step below — the files snapshotted above are what makes it whole again.
        try? attachments.removeAll(for: cardID)
        registerUndo { $0.restore(card, boardID: boardID, at: cardIdx, files: files) }
    }

    /// The inverse of `deleteCard`: the card goes back where it was in the flat array, which
    /// is also where it was in its column. Registers the delete as its own inverse. `files`
    /// are the attachment bytes the card carried, snapshotted by the delete since the
    /// `AttachmentStore` no longer has them.
    private func restore(_ card: Card, boardID: UUID, at index: Int, files: [(String, Data)] = []) {
        guard let idx = try? boardIndex(boardID) else { return }
        for (name, data) in files { try? attachments.write(data, name: name, to: card.id) }
        boards[idx].cards.insert(card, at: min(index, boards[idx].cards.count))
        try? persist(at: idx)
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

    public func addGlobalColumn(name: String) throws {
        globalColumns.append(BoardColumn(name: try validated(name)))
        try saveIndex()
    }

    public func addExtraColumn(boardID: UUID, name: String) throws {
        let idx = try boardIndex(boardID)
        boards[idx].extraColumns.append(BoardColumn(name: try validated(name)))
        try persist(at: idx)
    }

    /// `boardID` nil = a global column; otherwise that board's own extra column.
    public func renameColumn(id: UUID, to name: String, boardID: UUID?) throws {
        let trimmed = try validated(name)
        try mutateColumn(id: id, boardID: boardID) { $0.name = trimmed }
    }

    public func setColumnDone(id: UUID, _ isDone: Bool, boardID: UUID?) throws {
        try mutateColumn(id: id, boardID: boardID) { $0.isDone = isDone }
    }

    /// Deleting a column never deletes work: its cards move to the first global column.
    /// That last global column is the fallback, so it cannot itself be removed.
    public func deleteColumn(id: UUID, boardID: UUID?) throws {
        if let boardID {
            let idx = try boardIndex(boardID)
            guard boards[idx].extraColumns.contains(where: { $0.id == id }) else {
                throw BoardStoreError.columnNotFound(id)
            }
            boards[idx].extraColumns.removeAll { $0.id == id }
            reassignCards(from: id, boardIndex: idx)
            try persist(at: idx)
            return
        }
        guard globalColumns.contains(where: { $0.id == id }) else { throw BoardStoreError.columnNotFound(id) }
        guard globalColumns.count > 1 else { throw BoardStoreError.lastColumn }
        globalColumns.removeAll { $0.id == id }
        try saveIndex()
        for idx in boards.indices {
            reassignCards(from: id, boardIndex: idx)
            try persist(at: idx)
        }
    }

    private func reassignCards(from columnID: UUID, boardIndex idx: Int) {
        guard let fallback = globalColumns.first?.id else { return }
        for cardIdx in boards[idx].cards.indices where boards[idx].cards[cardIdx].columnID == columnID {
            boards[idx].cards[cardIdx].columnID = fallback
        }
    }

    private func mutateColumn(id: UUID, boardID: UUID?, _ change: (inout BoardColumn) -> Void) throws {
        if let boardID {
            let idx = try boardIndex(boardID)
            guard let colIdx = boards[idx].extraColumns.firstIndex(where: { $0.id == id }) else {
                throw BoardStoreError.columnNotFound(id)
            }
            change(&boards[idx].extraColumns[colIdx])
            try persist(at: idx)
        } else {
            guard let colIdx = globalColumns.firstIndex(where: { $0.id == id }) else {
                throw BoardStoreError.columnNotFound(id)
            }
            change(&globalColumns[colIdx])
            try saveIndex()
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
                guard let due = card.due, due > now, !doneColumns.contains(card.columnID) else { return nil }
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

    private func saveIndex() throws {
        let index = Index(boardOrder: boards.map(\.id), globalColumns: globalColumns, labels: labels)
        try Self.encoder.encode(index).write(to: indexURL, options: .atomic)
    }

    private func write(_ board: Board) throws {
        try Self.encoder.encode(board).write(to: boardURL(board.id), options: .atomic)
    }

    /// Persists the board at `index` after an in-memory mutation.
    private func persist(at index: Int) throws {
        try write(boards[index])
    }
}
