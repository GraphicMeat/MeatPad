import Foundation

public enum BoardStoreError: Error, Equatable {
    case boardNotFound(UUID)
    case cardNotFound(UUID)
    case columnNotFound(UUID)
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
    }

    /// `defaultColumnNames` is injected so the app can seed localized names on first run —
    /// MeatPadKit has no string catalog of its own.
    public init(rootURL: URL,
                defaultColumnNames: (todo: String, inProgress: String, done: String) = ("Todo", "In Progress", "Done")) throws {
        self.rootURL = rootURL
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

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
        _ = try boardIndex(id)
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

    @discardableResult
    public func addCard(boardID: UUID, columnID: UUID, title: String) throws -> Card {
        let idx = try boardIndex(boardID)
        guard columns(for: boards[idx]).contains(where: { $0.id == columnID }) else {
            throw BoardStoreError.columnNotFound(columnID)
        }
        let card = Card(title: try validated(title), columnID: columnID)
        boards[idx].cards.append(card)
        try persist(at: idx)
        return card
    }

    /// Replaces a card wholesale and stamps `modified`. Callers edit a copy and hand it back.
    public func updateCard(boardID: UUID, card: Card) throws {
        let idx = try boardIndex(boardID)
        guard let cardIdx = boards[idx].cards.firstIndex(where: { $0.id == card.id }) else {
            throw BoardStoreError.cardNotFound(card.id)
        }
        var updated = card
        updated.title = try validated(card.title)
        updated.modified = Date()
        boards[idx].cards[cardIdx] = updated
        try persist(at: idx)
    }

    public func deleteCard(boardID: UUID, cardID: UUID) throws {
        let idx = try boardIndex(boardID)
        guard boards[idx].cards.contains(where: { $0.id == cardID }) else {
            throw BoardStoreError.cardNotFound(cardID)
        }
        boards[idx].cards.removeAll { $0.id == cardID }
        try persist(at: idx)
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
        card.columnID = toColumn

        // Translate the column-local index into an index in the flat `cards` array.
        let siblings = boards[idx].cards.enumerated().filter { $0.element.columnID == toColumn }
        let clamped = max(0, min(index, siblings.count))
        let insertAt = clamped < siblings.count ? siblings[clamped].offset : boards[idx].cards.count
        boards[idx].cards.insert(card, at: insertAt)
        try persist(at: idx)
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
        let index = Index(boardOrder: boards.map(\.id), globalColumns: globalColumns)
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
