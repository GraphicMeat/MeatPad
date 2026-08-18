import SwiftUI
import MeatPadKit

/// Which board the window is showing. Raw-string encoded for @SceneStorage, same shape as
/// `FolderSelection` in the notes browser.
enum BoardSelection: Hashable, RawRepresentable {
    case allBoards
    case board(UUID)

    var rawValue: String {
        switch self {
        case .allBoards: return "all"
        case .board(let id): return "b:\(id.uuidString)"
        }
    }

    init?(rawValue: String) {
        if rawValue == "all" {
            self = .allBoards
        } else if rawValue.hasPrefix("b:"), let id = UUID(uuidString: String(rawValue.dropFirst(2))) {
            self = .board(id)
        } else {
            return nil
        }
    }
}

/// Content of the `Window("Boards")` scene: a board sidebar and the columns for whichever
/// board is selected ("All Boards" merges every board into the global columns).
struct BoardWindow: View {
    static let windowID = "boards"

    // Observed directly: nested ObservableObject changes don't propagate through AppModel's
    // @EnvironmentObject, so the sidebar would go stale on create/rename/delete.
    @ObservedObject private var store = AppModel.shared.boardStore
    @ObservedObject private var appModel = AppModel.shared

    @SceneStorage("board.selection") private var selection: BoardSelection = .allBoards
    @State private var selectedCard: UUID?
    @State private var newBoardShown = false
    @State private var nameDraft = ""
    @State private var renameTarget: UUID?
    @State private var deleteTarget: UUID?
    @State private var boardError: String?

    private var selectedBoard: Board? {
        guard case .board(let id) = selection else { return nil }
        return store.boards.first { $0.id == id }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .background { AmbientGlassBackground() }
        .frame(minWidth: 900, minHeight: 520)
        .onAppear { AppModel.shared.boardWindowDidAppear(); consumeReveal() }
        .onChange(of: appModel.pendingBoardReveal) { _, _ in consumeReveal() }
        .onDisappear { AppModel.shared.boardWindowDidDisappear() }
        .onChange(of: selection) { _, _ in
            // A reveal sets board and card together; clearing here would undo it.
            if appModel.pendingBoardReveal == nil { selectedCard = nil }
        }
        .alert("New Board", isPresented: $newBoardShown) {
            TextField("Name", text: $nameDraft)
            Button("Create") {
                runBoardOp {
                    let board = try store.createBoard(name: nameDraft)
                    selection = .board(board.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Board", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $nameDraft)
            Button("Rename") {
                if let id = renameTarget {
                    let name = nameDraft
                    runBoardOp { try store.renameBoard(id: id, to: name) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete “\(store.boards.first { $0.id == deleteTarget }?.name ?? "")”? Its cards are deleted with it.",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Board", role: .destructive) {
                if let id = deleteTarget {
                    runBoardOp {
                        try store.deleteBoard(id: id)
                        if case .board(id) = selection { selection = .allBoards }
                    }
                }
            }
        } message: {
            Text("This can't be undone.")
        }
        .alert("Board Error", isPresented: Binding(get: { boardError != nil }, set: { if !$0 { boardError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(boardError ?? "")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            row(.allBoards, name: String(localized: "All Boards"), icon: "square.grid.2x2",
                count: store.boards.reduce(0) { $0 + $1.cards.count })
            ForEach(store.boards) { board in
                row(.board(board.id), name: board.name, icon: "rectangle.split.3x1", count: board.cards.count)
                    .contextMenu {
                        Button("Rename…") { nameDraft = board.name; renameTarget = board.id }
                        Button("Delete…", role: .destructive) { deleteTarget = board.id }
                    }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        .toolbar {
            Button { nameDraft = ""; newBoardShown = true } label: {
                Label("New Board", systemImage: "plus")
            }
            .help(String(localized: "New Board"))
            .accessibilityIdentifier("board.new")
        }
    }

    private func row(_ value: BoardSelection, name: String, icon: String, count: Int) -> some View {
        Label {
            HStack {
                Text(name).lineLimit(1)
                Spacer()
                Text("\(count)").foregroundStyle(.secondary).font(.caption)
            }
        } icon: {
            Image(systemName: icon).foregroundStyle(MeatPadGlass.tint.gradient)
        }
        .tag(value)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if store.boards.isEmpty {
            ContentUnavailableView {
                Label("No Boards", systemImage: "square.grid.2x2")
            } description: {
                Text("Create a board for a project to start tracking work.")
            } actions: {
                Button("New Board") { nameDraft = ""; newBoardShown = true }
            }
        } else {
            BoardColumnsView(store: store, board: selectedBoard, selectedCard: $selectedCard)
        }
    }

    /// "Reveal in Board" from a note: select its board and card, then clear the request so
    /// re-opening the window later doesn't jump again.
    private func consumeReveal() {
        guard let reveal = appModel.pendingBoardReveal else { return }
        selection = .board(reveal.boardID)
        selectedCard = reveal.cardID
        appModel.pendingBoardReveal = nil
    }

    /// Board ops all fail the same way (name taken, disk trouble) — one alert for the lot,
    /// same shape as the notes browser's `runFolderOp`.
    private func runBoardOp(_ op: () throws -> Void) {
        do { try op() } catch { boardError = error.localizedDescription }
    }
}
