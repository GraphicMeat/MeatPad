import Foundation

/// One column on a board. Identity is the UUID, never the name — renaming a column must
/// not orphan its cards, and the name is user-editable and localized.
public struct BoardColumn: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// Cards here are finished: due dates render struck through and never notify.
    public var isDone: Bool

    public init(id: UUID = UUID(), name: String, isDone: Bool = false) {
        self.id = id
        self.name = name
        self.isDone = isDone
    }
}

/// A task on a board. Cards are their own entity — a card is not a note, though it may
/// link to one (`noteID`).
public struct Card: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var body: String?
    public var due: Date?
    public var columnID: UUID
    /// The only stored side of the note link; the note→card direction is a lookup
    /// (`BoardStore.card(forNote:)`), so the two can never drift apart.
    public var noteID: UUID?
    public var created: Date
    public var modified: Date

    public init(id: UUID = UUID(), title: String, body: String? = nil, due: Date? = nil,
                columnID: UUID, noteID: UUID? = nil, created: Date = Date(), modified: Date = Date()) {
        self.id = id
        self.title = title
        self.body = body
        self.due = due
        self.columnID = columnID
        self.noteID = noteID
        self.created = created
        self.modified = modified
    }
}

/// One project's board. `cards` order IS the display order; filtering by `columnID` yields
/// a column's cards already ordered.
public struct Board: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// Board-specific columns, rendered after the global ones.
    public var extraColumns: [BoardColumn]
    public var cards: [Card]

    public init(id: UUID = UUID(), name: String, extraColumns: [BoardColumn] = [], cards: [Card] = []) {
        self.id = id
        self.name = name
        self.extraColumns = extraColumns
        self.cards = cards
    }
}
