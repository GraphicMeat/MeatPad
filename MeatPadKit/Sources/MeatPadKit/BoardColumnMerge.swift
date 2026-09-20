import Foundation

/// One column, on one board — the unit the All Boards "combined column" picker selects. A
/// bare column id is not enough: the default Todo/In Progress/Done columns share fixed UUIDs
/// across every board (`BoardStore.defaultColumnTemplate`), so a column id alone would drag
/// every board's Todo in at once the moment one was picked. The pair is what lets the picker
/// mean "this board's Todo", not "Todo everywhere".
public struct ColumnKey: Hashable, Codable, Sendable {
    public let boardID: UUID
    public let columnID: UUID

    public init(boardID: UUID, columnID: UUID) {
        self.boardID = boardID
        self.columnID = columnID
    }

    /// `"<boardUUID>:<columnUUID>"` — the wire form `BoardColumnMerge` reads and writes.
    fileprivate var wire: String { "\(boardID.uuidString):\(columnID.uuidString)" }
}

/// Converts the All Boards combined-column selection to and from the single string an
/// `AppStorage` value can hold.
public enum BoardColumnMerge {
    /// Comma-joined `"board:column"` entries. Malformed or unparseable entries (a hand-edited
    /// default, a truncated value) are dropped rather than failing the whole selection.
    public static func parse(_ raw: String) -> Set<ColumnKey> {
        Set(raw.split(separator: ",").compactMap { entry -> ColumnKey? in
            let parts = entry.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  let boardID = UUID(uuidString: String(parts[0])),
                  let columnID = UUID(uuidString: String(parts[1]))
            else { return nil }
            return ColumnKey(boardID: boardID, columnID: columnID)
        })
    }

    /// Sorted by the wire text itself so the same set of keys always serializes to the same
    /// string, regardless of `Set`'s own (unordered) iteration order — otherwise the
    /// `AppStorage` value would churn, and with it every observer of that key, on every launch.
    public static func serialize(_ keys: Set<ColumnKey>) -> String {
        keys.map(\.wire).sorted().joined(separator: ",")
    }
}
