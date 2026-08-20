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
    @State private var nameDraft = ""
    @State private var renameTarget: ColumnRef?
    @State private var deleteTarget: ColumnRef?
    @State private var addColumnTarget: AddColumnScope?
    /// Where a dragged card would land right now — drives the insertion bar and the column
    /// highlight, so a drag shows its destination instead of guessing.
    @State private var dropTarget: DropTarget?

    private struct DropTarget: Equatable {
        let column: UUID
        let index: Int
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
        }
        .alert("Rename Column", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $nameDraft)
                .ringlessField()
            Button("Rename") {
                if let target = renameTarget {
                    try? store.renameColumn(id: target.id, to: nameDraft, boardID: target.boardID)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(addColumnTitle, isPresented: Binding(get: { addColumnTarget != nil }, set: { if !$0 { addColumnTarget = nil } })) {
            TextField("Name", text: $nameDraft)
                .ringlessField()
            Button("Add") {
                switch addColumnTarget {
                case .global: try? store.addGlobalColumn(name: nameDraft)
                case .board(let id): try? store.addExtraColumn(boardID: id, name: nameDraft)
                case nil: break
                }
            }
            Button("Cancel", role: .cancel) {}
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
    }

    private var addColumnTitle: String {
        if case .board = addColumnTarget { return String(localized: "New Board Column") }
        return String(localized: "New Column")
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
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    TextField("Add card", text: Binding(
                        get: { drafts[column.id] ?? "" },
                        set: { drafts[column.id] = $0 }
                    ))
                    .textFieldStyle(.plain)
                    .onSubmit { addCard(to: column, in: board) }
                    .accessibilityIdentifier("column.addCard")
                }
                .ringlessField()
            }

            ForEach(Array(items.enumerated()), id: \.element.id) { index, ref in
                insertionBar(for: column, at: index)
                cardRow(ref, in: column, at: index)
            }
            insertionBar(for: column, at: items.count)
            Spacer(minLength: 0)
        }
        .frame(width: 280, alignment: .leading)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(MeatPadGlass.violet.opacity(isTargeting(column) ? 0.10 : 0))
        }
        .animation(.snappy(duration: 0.18), value: dropTarget)
        // Column-level drop appends; the per-card drop inserts above the card it lands on.
        .dropDestination(for: String.self) { ids, _ in
            defer { dropTarget = nil }
            return move(ids, to: column.id, index: items.count)
        } isTargeted: { targeted in
            if targeted {
                if dropTarget?.column != column.id { dropTarget = DropTarget(column: column.id, index: items.count) }
            } else if dropTarget?.column == column.id {
                dropTarget = nil
            }
        }
    }

    private func isTargeting(_ column: BoardColumn) -> Bool {
        dropTarget?.column == column.id
    }

    /// The gap a dropped card would slot into. Zero height until it is the live target, so
    /// the stack doesn't shift around while nothing is being dragged.
    @ViewBuilder
    private func insertionBar(for column: BoardColumn, at index: Int) -> some View {
        let active = dropTarget == DropTarget(column: column.id, index: index)
        Capsule(style: .continuous)
            .fill(MeatPadGlass.violet)
            .frame(height: active ? 3 : 0)
            .opacity(active ? 1 : 0)
            .padding(.vertical, active ? 2 : 0)
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
            ForEach(otherCards) { ref in
                cardRow(ref, in: nil)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 280, alignment: .leading)
    }

    // MARK: - Cards

    private func cardRow(_ ref: CardRef, in column: BoardColumn?, at index: Int = 0) -> some View {
        CardView(
            store: store,
            boardID: ref.board.id,
            card: ref.card,
            boardBadge: board == nil ? ref.board.name : nil,
            isDone: column?.isDone ?? columnIsDone(ref),
            isSelected: selectedCard == ref.card.id
        )
        .contentShape(Rectangle())
        .onTapGesture { selectedCard = ref.card.id }
        .draggable(ref.card.id.uuidString) {
            // A compact chip drags better than a full-card snapshot, and shows what's moving.
            Text(ref.card.title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(.thinMaterial))
        }
        // Only real columns accept drops — "Other" has no single target column to move into.
        .dropDestination(for: String.self) { ids, _ in
            guard let column else { return false }
            defer { dropTarget = nil }
            return move(ids, to: column.id, index: index)
        } isTargeted: { targeted in
            guard let column else { return }
            if targeted {
                dropTarget = DropTarget(column: column.id, index: index)
            } else if dropTarget == DropTarget(column: column.id, index: index) {
                dropTarget = nil
            }
        }
    }

    private func columnIsDone(_ ref: CardRef) -> Bool {
        store.columns(for: ref.board).first { $0.id == ref.card.columnID }?.isDone ?? false
    }

    /// A card always moves within its own board — in the all-boards view the destination
    /// column is a global one, which every board shares.
    @discardableResult
    private func move(_ ids: [String], to columnID: UUID, index: Int) -> Bool {
        var moved = false
        withAnimation(.snappy(duration: 0.22)) {
            for id in ids.compactMap({ UUID(uuidString: $0) }) {
                guard let owner = store.boards.first(where: { $0.cards.contains { $0.id == id } }) else { continue }
                try? store.moveCard(id: id, boardID: owner.id, toColumn: columnID, index: index)
                moved = true
            }
        }
        return moved
    }

    private func addCard(to column: BoardColumn, in board: Board) {
        let title = drafts[column.id] ?? ""
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        _ = try? store.addCard(boardID: board.id, columnID: column.id, title: title)
        drafts[column.id] = ""
    }
}
