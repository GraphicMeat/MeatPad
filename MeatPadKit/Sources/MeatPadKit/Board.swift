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
    /// The column's look as a picture instead: a file name in the store's `AttachmentStore`,
    /// owned by the column's own id — exactly like `Board.image`. Never set alongside `emoji`;
    /// `BoardStore` is what enforces the one-look rule. Optional so older board files decode.
    public var image: String?

    public init(id: UUID = UUID(), name: String, isDone: Bool = false, emoji: String? = nil, image: String? = nil) {
        self.id = id
        self.name = name
        self.isDone = isDone
        self.emoji = emoji
        self.image = image
    }
}

/// A tag a card can carry. Labels are global to the store — "Bug" means one thing on every
/// board, so the All Boards overview can filter by it. Unlike columns, a label has no
/// per-board copy: deleting one really does remove it everywhere, and the UI says so.
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
    /// The card's own colour, painting its whole cell the way a calendar paints an event.
    /// One per card, unlike labels: a card can carry five tags but it can only look like one
    /// thing. nil is not a missing colour, it is the plain glass card — the default, and what
    /// every board file written before this decodes as.
    public var color: RGBAColor?
    /// Image files attached to the card, by name, in display order — files live in the
    /// store's `AttachmentStore`. Optional for the same reason as `labelIDs`: board files
    /// written before attachments existed must still decode.
    public var attachments: [String]?
    public var created: Date
    public var modified: Date
    /// When the card was archived. Archived cards keep their column and position and are hidden
    /// unless the board's Show Archived toggle is on. Optional so older board files decode.
    public var archived: Date?

    public init(id: UUID = UUID(), title: String, body: String? = nil, due: Date? = nil,
                columnID: UUID, noteID: UUID? = nil, labelIDs: [UUID]? = nil,
                color: RGBAColor? = nil, attachments: [String]? = nil,
                created: Date = Date(), modified: Date = Date()) {
        self.id = id
        self.title = title
        self.body = body
        self.due = due
        self.columnID = columnID
        self.noteID = noteID
        self.labelIDs = labelIDs
        self.color = color
        self.attachments = attachments
        self.created = created
        self.modified = modified
    }

    /// Any label, not all: an empty filter shows every card, otherwise the card needs one of
    /// the selected labels. That is what a chip filter is expected to do — narrowing to cards
    /// carrying *every* selected label is a different feature.
    ///
    /// The text query narrows further — both have to pass, so search runs inside whatever the
    /// chips already left. Substring, not fuzzy: this is a filter you watch cards fall out of
    /// while typing, and an unrelated card surviving on a fuzzy score reads as a bug.
    /// `localizedStandardContains` is the Finder's rule — case- and diacritic-insensitive.
    public func matches(labels filter: Set<UUID>, text query: String = "", showArchived: Bool = false) -> Bool {
        guard showArchived || archived == nil else { return false }
        guard filter.isEmpty || (labelIDs ?? []).contains(where: { filter.contains($0) }) else { return false }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return title.localizedStandardContains(needle) || body?.localizedStandardContains(needle) == true
    }

    /// Every place `query` occurs in `text`, by the same rule `matches` filters with — so a
    /// card the search keeps always has something to highlight. `localizedStandardContains`
    /// is documented as exactly these options with the current locale; spelling them out is
    /// what lets this walk every occurrence instead of answering yes/no.
    ///
    /// NSRanges converted from the String ranges Foundation hands back, never counted from
    /// `needle.count`: a diacritic-insensitive hit can be a different length from the query,
    /// and anything past an emoji is a different offset in UTF-16 than in Characters.
    public static func matchRanges(of query: String, in text: String) -> [NSRange] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var ranges: [NSRange] = []
        var searchFrom = text.startIndex
        while searchFrom < text.endIndex,
              let hit = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive],
                                   range: searchFrom..<text.endIndex, locale: .current) {
            ranges.append(NSRange(hit, in: text))
            // An empty hit can't happen for a non-empty needle, but a loop that doesn't
            // advance would hang the card face — step at least one character regardless.
            searchFrom = hit.upperBound > hit.lowerBound ? hit.upperBound : text.index(after: hit.lowerBound)
        }
        return ranges
    }

    /// The card's text as separate lines, for "Split into Cards": the title's lines, then the
    /// notes', each trimmed and stripped of a list marker, blank lines dropped. Fewer than two
    /// means there is nothing to split.
    public var splitLines: [String] {
        CardTextSplit.lines(from: title + "\n" + (body ?? ""))
    }

    /// What the card's copy button puts on the pasteboard: the title, then the notes after a
    /// blank line when there are any.
    public var clipboardText: String {
        let notes = (body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty else { return title }
        return title.isEmpty ? notes : title + "\n\n" + notes
    }

    /// Nothing written on it yet — what the column's `+` makes, and the only state in which
    /// the face offers to paste the clipboard into the card.
    public var isBlank: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (body ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// What each line of a card becomes when it is split into cards.
public enum CardSplitMode: Equatable, Sendable {
    /// The line is the new card's title.
    case titles
    /// The line is the new card's notes. `titles`, one per line, are written above them; nil (or
    /// a list of the wrong length — the card was edited while they were being written) leaves
    /// the cards untitled. A title that already is the whole line leaves its notes empty.
    case notes(titles: [String]? = nil)

    func faces(for lines: [String]) -> [(title: String, body: String?)] {
        switch self {
        case .titles:
            return lines.map { ($0, nil) }
        case .notes(let titles):
            let usable = titles?.count == lines.count ? titles : nil
            return lines.indices.map { i in
                let title = usable?[i].trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return (title, title == lines[i] ? nil : lines[i])
            }
        }
    }
}

/// One project's board. `cards` order IS the display order; filtering by `columnID` yields
/// a column's cards already ordered.
public struct Board: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// This board's own columns, name and identity entirely its own — deleting or renaming one
    /// never touches any other board. A new board starts with its own copy of
    /// `BoardStore.defaultColumnTemplate` (Todo/In Progress/Done), sharing those column ids
    /// with every other board's copy only so the All Boards overview can pool cards into one
    /// "Todo" bucket across boards; nothing else depends on that overlap.
    public var extraColumns: [BoardColumn]
    public var cards: [Card]
    /// The board's own look, one emoji — exactly like `BoardColumn.emoji`. Optional so board
    /// files written before icons decode unchanged.
    public var icon: String?
    /// The board's own look as a picture instead: a file name in the store's
    /// `AttachmentStore`, owned by the board's id. Never set alongside `icon` — a board has
    /// one look, and `BoardStore` is what enforces that.
    public var image: String?
    /// This board's column order as ids. nil = `extraColumns`' own order.
    /// Ids not listed (a column added later) append in default order; stale ids are ignored.
    public var columnOrder: [UUID]? = nil
    /// When the board was created, for the `.created` sidebar sort. Optional and never
    /// backfilled — a board file written before this exists simply sorts as `.distantPast`
    /// (see `SidebarSorter`), same stance as every other optional-for-old-files field here.
    public var created: Date?

    public init(id: UUID = UUID(), name: String, extraColumns: [BoardColumn] = [], cards: [Card] = [],
                icon: String? = nil, image: String? = nil, created: Date? = nil) {
        self.id = id
        self.name = name
        self.extraColumns = extraColumns
        self.cards = cards
        self.icon = icon
        self.image = image
        self.created = created
    }
}

/// A card, column or whole board someone deleted, kept around for recovery — the board
/// equivalent of `NoteStore`'s trashed notes, except there is no per-item file to move: one
/// `trash.json` in `BoardStore`'s root holds every entry from every board, so a single "Board
/// Trash" view can list and restore across all of them.
///
/// Only one of `card`/`column`/`board` is ever set, matching `kind` — a flat struct instead of
/// an enum-with-payload so it stays a plain `Codable` value like every other model here.
/// Attachment files for a trashed card (or a trashed column/board's cards) are never deleted
/// at trash time — only when the entry is purged — so restoring finds them exactly where a
/// live card's would be.
public struct TrashEntry: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case card, column, board }

    public var id: UUID
    public var kind: Kind
    public var deletedAt: Date
    /// Where this came from — for `.board`, the deleted board's own id, so a restore can put
    /// it back in the same slot in spirit (appended, since board order is otherwise a flat
    /// list with no meaningful "original position" to restore).
    public var boardID: UUID
    /// Snapshotted at delete time so a trash row can say "from Marketing" even if the board
    /// itself no longer exists (only possible for `.card`/`.column`, whose board was deleted
    /// out from under them after they were trashed).
    public var boardName: String
    public var card: Card?
    public var column: BoardColumn?
    /// `.column` only: the cards that were sitting in it, exactly as they were — restoring
    /// re-creates the column and moves these specific cards (by id, if still on the board)
    /// back into it.
    public var columnCards: [Card]?
    public var board: Board?

    public init(kind: Kind, boardID: UUID, boardName: String, card: Card? = nil,
                column: BoardColumn? = nil, columnCards: [Card]? = nil, board: Board? = nil,
                id: UUID = UUID(), deletedAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.deletedAt = deletedAt
        self.boardID = boardID
        self.boardName = boardName
        self.card = card
        self.column = column
        self.columnCards = columnCards
        self.board = board
    }

    /// One line for a trash row: the name of whatever got deleted.
    public var title: String {
        switch kind {
        // An untitled card names itself by its notes — a blank card can be trashed now, and a
        // row with nothing written on it is a row you cannot tell from the one above it.
        case .card:
            guard let card else { return "" }
            guard card.title.isEmpty else { return card.title }
            return (card.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n").first ?? ""
        case .column: return column?.name ?? ""
        case .board: return board?.name ?? ""
        }
    }
}

/// How much of every card the board draws. A view setting rather than a filter — it hides
/// nothing, it only decides how tall a card is allowed to be — and it is remembered across
/// launches, because density is a preference and not a search you'd forget you left on.
public enum CardDisplay: String, CaseIterable, Sendable {
    /// Titles clipped to one line, notes shut. The most cards per screen a column can hold.
    case compact
    /// The whole title, however many lines it takes; notes stay shut.
    case titles
    /// Everything: the whole title, and the notes already open.
    case full

    /// Cards open their notes only in `.full` — and only if they have any, which is the
    /// card's own business, not this setting's.
    public var notesOpen: Bool { self == .full }

    /// The lines a title may take. A count with a ceiling rather than `nil`: `lineLimit(nil)`
    /// leaves a vertical-axis `TextField` on a single line, and a `ClosedRange` limit doesn't
    /// let it grow either, so "unlimited" has to be spelled as a number. 30 is that number —
    /// a title needing more lines has a bigger problem than this setting.
    public var titleLines: Int { self == .compact ? 1 : 30 }
}
