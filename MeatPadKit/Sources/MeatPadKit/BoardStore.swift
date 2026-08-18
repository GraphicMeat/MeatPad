import Foundation

public enum BoardStoreError: Error, Equatable {
    case boardNotFound(UUID)
    case cardNotFound(UUID)
    case columnNotFound(UUID)
    case invalidName
    case lastColumn
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
            BoardColumn(name: defaultColumnNames.todo),
            BoardColumn(name: defaultColumnNames.inProgress),
            BoardColumn(name: defaultColumnNames.done, isDone: true),
        ]
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
