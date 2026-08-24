import Foundation

/// One column on a board. Identity is the UUID, never the name — renaming a column must
/// not orphan its cards, and the name is user-editable and localized.
public struct BoardColumn: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// Cards here are finished: due dates render struck through and never notify.
    public var isDone: Bool
    /// Shown before the name in the column header. Seeded for the default columns; nil for
    /// columns the user adds. Optional so older board files decode unchanged.
    public var emoji: String?

    public init(id: UUID = UUID(), name: String, isDone: Bool = false, emoji: String? = nil) {
        self.id = id
        self.name = name
        self.isDone = isDone
        self.emoji = emoji
    }
}

/// A tag a card can carry. Labels are global to the store, exactly like
/// `BoardStore.globalColumns` — "Bug" means one thing on every board, so the All Boards
/// overview can filter by it.
public struct CardLabel: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var color: RGBAColor

    public init(id: UUID = UUID(), name: String, color: RGBAColor) {
        self.id = id
        self.name = name
        self.color = color
    }

    /// Colours a new label is drawn from, least-used first — "a random nice colour" that
    /// cannot collide until the palette runs dry. Mid-saturation on purpose: these sit on
    /// translucent glass in both light and dark appearance.
    public static let palette: [RGBAColor] = [
        RGBAColor(hex: "#E5484D")!,
        RGBAColor(hex: "#F76B15")!,
        RGBAColor(hex: "#FFB224")!,
        RGBAColor(hex: "#99D52A")!,
        RGBAColor(hex: "#30A46C")!,
        RGBAColor(hex: "#12A594")!,
        RGBAColor(hex: "#00A2C7")!,
        RGBAColor(hex: "#3E63DD")!,
        RGBAColor(hex: "#7C66DC")!,
        RGBAColor(hex: "#BF7AF0")!,
        RGBAColor(hex: "#E93D82")!,
        RGBAColor(hex: "#AD7F58")!,
    ]
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
    /// Labels this card carries, in display order. Optional because Swift's synthesized
    /// decoder ignores default values — a board file written before labels existed would
    /// fail on a missing key, exactly like `BoardColumn.emoji`.
    public var labelIDs: [UUID]?
    public var created: Date
    public var modified: Date

    public init(id: UUID = UUID(), title: String, body: String? = nil, due: Date? = nil,
                columnID: UUID, noteID: UUID? = nil, labelIDs: [UUID]? = nil,
                created: Date = Date(), modified: Date = Date()) {
        self.id = id
        self.title = title
        self.body = body
        self.due = due
        self.columnID = columnID
        self.noteID = noteID
        self.labelIDs = labelIDs
        self.created = created
        self.modified = modified
    }

    /// Any, not all: an empty filter shows every card, otherwise the card needs one of the
    /// selected labels. That is what a chip filter is expected to do — narrowing to cards
    /// carrying *every* selected label is a different feature.
    public func matches(labels filter: Set<UUID>) -> Bool {
        filter.isEmpty || (labelIDs ?? []).contains { filter.contains($0) }
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
