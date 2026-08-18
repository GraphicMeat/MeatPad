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

    @State private var drafts: [UUID: String] = [:]

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

    private var selection: CardRef? {
        guard let selectedCard else { return nil }
        for board in store.boards where board.cards.contains(where: { $0.id == selectedCard }) {
            if let card = board.cards.first(where: { $0.id == selectedCard }) { return CardRef(board: board, card: card) }
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(renderedColumns) { column in
                        columnView(column)
                    }
                    if board == nil, !otherCards.isEmpty {
                        otherColumn
                    }
                }
                .padding(16)
            }
            if let selection {
                Divider()
                CardInspectorView(store: store, boardID: selection.board.id, card: selection.card) {
                    selectedCard = nil
                }
            }
        }
    }

    // MARK: - Columns

    private func cards(in column: BoardColumn) -> [CardRef] {
        if let board {
            let live = store.boards.first { $0.id == board.id } ?? board
            return store.cards(in: live, column: column.id).map { CardRef(board: live, card: $0) }
        }
        return store.boards.flatMap { board in
            store.cards(in: board, column: column.id).map { CardRef(board: board, card: $0) }
        }
    }

    /// All-boards only: cards parked in board-specific columns, which the shared column set
    /// cannot represent.
    private var otherCards: [CardRef] {
        let globals = Set(store.globalColumns.map(\.id))
        return store.boards.flatMap { board in
            board.cards.filter { !globals.contains($0.columnID) }.map { CardRef(board: board, card: $0) }
        }
    }

    private func columnView(_ column: BoardColumn) -> some View {
        let items = cards(in: column)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(column.name).font(.headline).lineLimit(1)
                if column.isDone {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                }
                Spacer()
                Text("\(items.count)").font(.caption).foregroundStyle(.secondary)
            }

            if let board {
                TextField("Add card", text: Binding(
                    get: { drafts[column.id] ?? "" },
                    set: { drafts[column.id] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .onSubmit { addCard(to: column, in: board) }
                .accessibilityIdentifier("column.addCard")
            }

            ForEach(items) { ref in
                cardRow(ref, in: column)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 280, alignment: .leading)
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
            ForEach(otherCards) { ref in
                cardRow(ref, in: nil)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 280, alignment: .leading)
    }

    // MARK: - Cards

    private func cardRow(_ ref: CardRef, in column: BoardColumn?) -> some View {
        let card = ref.card
        let isDone = column?.isDone ?? columnIsDone(ref)
        return VStack(alignment: .leading, spacing: 5) {
            Text(card.title).lineLimit(2).font(.body)
            if let body = card.body, !body.isEmpty {
                Text(body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 6) {
                if let due = card.due {
                    Label {
                        Text(due, format: .dateTime.month().day().hour().minute())
                    } icon: {
                        Image(systemName: "calendar")
                    }
                    .font(.caption2)
                    .foregroundStyle(dueColor(due, isDone: isDone))
                    .strikethrough(isDone)
                }
                if card.noteID != nil {
                    Image(systemName: "link").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if board == nil {
                    Text(ref.board.name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.quaternary))
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.thinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(selectedCard == card.id ? AnyShapeStyle(MeatPadGlass.tint) : AnyShapeStyle(.white.opacity(0.12)), lineWidth: 1)
                }
        }
        .contentShape(Rectangle())
        .onTapGesture { selectedCard = card.id }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// Overdue reads red, due today orange, everything else secondary — and a finished card
    /// is never "late".
    private func dueColor(_ due: Date, isDone: Bool) -> Color {
        if isDone { return .secondary }
        if due < Date() { return .red }
        if Calendar.current.isDateInToday(due) { return .orange }
        return .secondary
    }

    private func columnIsDone(_ ref: CardRef) -> Bool {
        store.columns(for: ref.board).first { $0.id == ref.card.columnID }?.isDone ?? false
    }

    private func addCard(to column: BoardColumn, in board: Board) {
        let title = drafts[column.id] ?? ""
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try? store.addCard(boardID: board.id, columnID: column.id, title: title)
        drafts[column.id] = ""
    }
}
