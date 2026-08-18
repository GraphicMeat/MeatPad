import SwiftUI
import AppKit
import MeatPadKit

/// Which folder the browser is showing. Raw-string encoded for @SceneStorage.
enum FolderSelection: Hashable, RawRepresentable {
    case all
    case defaultFolder          // the implicit "Notes" folder (Note.folder == nil)
    case folder(String)
    case trash
    case allBoards
    case board(UUID)

    var rawValue: String {
        switch self {
        case .all: return "all"
        case .defaultFolder: return "default"
        case .folder(let name): return "f:\(name)"
        case .trash: return "trash"
        case .allBoards: return "boards"
        case .board(let id): return "b:\(id.uuidString)"
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "all": self = .all
        case "default": self = .defaultFolder
        case "trash": self = .trash
        case "boards": self = .allBoards
        default:
            if rawValue.hasPrefix("f:") {
                self = .folder(String(rawValue.dropFirst(2)))
            } else if rawValue.hasPrefix("b:"), let id = UUID(uuidString: String(rawValue.dropFirst(2))) {
                self = .board(id)
            } else {
                return nil
            }
        }
    }

    /// The value new/moved notes get in this context: "All Notes" creates into the default folder.
    var noteFolder: String? {
        if case .folder(let name) = self { return name }
        return nil
    }

    /// True while the window is showing a board rather than notes.
    var isBoard: Bool {
        switch self {
        case .allBoards, .board: return true
        default: return false
        }
    }

    /// The selected board's id; nil for the All Boards overview and for any note selection.
    var boardID: UUID? {
        if case .board(let id) = self { return id }
        return nil
    }
}

/// Content of the `Window("All Notes", id: "all-notes")` scene: folders sidebar,
/// searchable note list for the selected folder, and a detail editor, reusing the same
/// `NoteEditorViewModel` autosave pipeline as a standalone note window.
struct NotesBrowserWindow: View {
    // Observed directly: nested ObservableObject changes don't propagate through
    // AppModel's @EnvironmentObject, so the list would go stale on create/trash/save.
    @ObservedObject private var noteStore = AppModel.shared.noteStore
    // Boards share this window with notes — same sidebar, same three columns. Observed
    // directly for the same reason noteStore is.
    @ObservedObject private var boardStore = AppModel.shared.boardStore
    @ObservedObject private var appModel = AppModel.shared
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""
    @State private var selection: Set<UUID> = []
    @SceneStorage("notesBrowser.folder") private var folderSelection: FolderSelection = .all

    // New Folder / Rename alerts.
    @State private var folderNameDraft = ""
    @State private var newFolderShown = false
    @State private var renameTarget: String?
    @State private var deleteTarget: String?
    @State private var permanentDeleteTarget: Set<UUID>?
    @State private var folderError: String?
    @State private var newBoardShown = false
    @State private var boardNameDraft = ""
    @State private var boardRenameTarget: UUID?
    @State private var boardDeleteTarget: UUID?
    /// The card whose inspector fills the detail column while a board is selected.
    @State private var selectedCard: UUID?

    private var folderFilteredNotes: [Note] {
        if case .trash = folderSelection { return noteStore.trashedNotes }
        var notes = noteStore.notes
        switch folderSelection {
        // Board selections don't list notes at all — the middle column shows the board.
        case .all, .trash, .allBoards, .board: break
        case .defaultFolder:
            // Unknown-folder notes (folder name absent from folders.json) fall back here.
            notes = notes.filter { $0.folder == nil || !noteStore.folders.contains($0.folder!) }
        case .folder(let name):
            notes = notes.filter { $0.folder == name }
        }
        return notes
    }

    /// nil when not searching (empty query) — callers fall back to plain folder order.
    /// Synchronous: the index is in-memory and note counts are small, so no debounce/async.
    private var searchMatches: [NoteSearchMatch]? {
        // Trashed notes aren't indexed — show a plain list, no search ordering.
        if case .trash = folderSelection { return nil }
        guard !query.isEmpty else { return nil }
        return noteStore.searchIndex.search(query, notes: folderFilteredNotes)
    }

    /// List data source, kept `[Note]`-shaped so selection/@SceneStorage/etc. are untouched.
    /// While searching, order follows `searchMatches` (title matches first).
    private var filtered: [Note] {
        guard let searchMatches else { return folderFilteredNotes }
        let byID = Dictionary(uniqueKeysWithValues: noteStore.notes.map { ($0.id, $0) })
        return searchMatches.compactMap { byID[$0.noteID] }
    }

    /// Row-decoration lookup for the excerpt line, keyed by note id.
    private var matchByID: [UUID: NoteSearchMatch] {
        guard let searchMatches else { return [:] }
        return Dictionary(uniqueKeysWithValues: searchMatches.map { ($0.noteID, $0) })
    }

    var body: some View {
        NavigationSplitView {
            folderSidebar
        } content: {
            // Same three columns serve both modes: board columns take the wide middle, the
            // card inspector takes the detail column the note editor otherwise fills.
            if folderSelection.isBoard {
                boardColumns
            } else {
                noteList
            }
        } detail: {
            if folderSelection.isBoard {
                boardDetail
            } else {
                detail
            }
        }
        .background { AmbientGlassBackground() }
        .frame(minWidth: 860, minHeight: 480)
        .onAppear { AppModel.shared.browserWindowDidAppear() }
        .onDisappear { AppModel.shared.browserWindowDidDisappear() }
        .onChange(of: folderSelection) { _, _ in
            selection = []
            // A reveal sets board and card together; clearing here would undo it.
            if appModel.pendingBoardReveal == nil { selectedCard = nil }
        }
        .onAppear { consumeBoardReveal() }
        .onChange(of: appModel.pendingBoardReveal) { _, _ in consumeBoardReveal() }
        // Search-hit reveal only makes sense for a single note — a multi-selection has no
        // one editor to scroll.
        .onChange(of: selection) { _, newValue in
            if newValue.count == 1, let id = newValue.first { revealMatch(for: id) }
        }
        .focusedSceneValue(\.notesBrowser, NotesBrowserActions(
            newFolder: { folderNameDraft = ""; newFolderShown = true },
            trashSelection: trashSelection,
            restoreSelection: restoreSelection,
            openSelectionInNewWindow: openSelectionInNewWindow,
            hasSelection: !selection.isEmpty,
            isTrash: folderSelection == .trash
        ))
        .alert("New Folder", isPresented: $newFolderShown) {
            TextField("Name", text: $folderNameDraft)
            Button("Create") { runFolderOp { try noteStore.createFolder(folderNameDraft) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New Board", isPresented: $newBoardShown) {
            TextField("Name", text: $boardNameDraft)
            Button("Create") {
                runFolderOp {
                    let board = try boardStore.createBoard(name: boardNameDraft)
                    folderSelection = .board(board.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Folder", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $folderNameDraft)
            Button("Rename") {
                if let old = renameTarget {
                    let new = folderNameDraft
                    runFolderOp {
                        try noteStore.renameFolder(old, to: new)
                        if case .folder(old) = folderSelection { folderSelection = .folder(new) }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Board", isPresented: boardRenamePresented) {
            TextField("Name", text: $boardNameDraft)
            Button("Rename") {
                if let id = boardRenameTarget {
                    let name = boardNameDraft
                    runFolderOp { try boardStore.renameBoard(id: id, to: name) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            boardDeleteTitle,
            isPresented: boardDeletePresented,
            titleVisibility: .visible
        ) {
            Button("Delete Board", role: .destructive) {
                if let id = boardDeleteTarget {
                    runFolderOp {
                        try boardStore.deleteBoard(id: id)
                        if folderSelection == .board(id) { folderSelection = .allBoards }
                    }
                }
            }
        } message: {
            Text("This can’t be undone.")
        }
        .confirmationDialog(
            "Delete “\(deleteTarget ?? "")”? Its notes move to the trash.",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Folder", role: .destructive) {
                if let name = deleteTarget {
                    runFolderOp {
                        try noteStore.deleteFolder(name)
                        if case .folder(name) = folderSelection { folderSelection = .all }
                    }
                }
            }
        }
        .confirmationDialog(
            permanentDeleteTitle,
            isPresented: Binding(get: { permanentDeleteTarget != nil }, set: { if !$0 { permanentDeleteTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                if let ids = permanentDeleteTarget {
                    for id in ids { try? noteStore.delete(id: id) }
                    selection.subtract(ids)
                }
            }
        } message: {
            Text("This can’t be undone.")
        }
        .alert("Folder Error", isPresented: Binding(get: { folderError != nil }, set: { if !$0 { folderError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(folderError ?? "")
        }
    }

    // MARK: - Columns

    @ViewBuilder
    private var folderSidebar: some View {
        List(selection: $folderSelection) {
            folderRow(.all, name: String(localized: "All Notes"), icon: "tray.full", count: noteStore.notes.count)
            folderRow(.defaultFolder, name: String(localized: "Notes"), icon: "folder", count: noteStore.notes.filter { $0.folder == nil || !noteStore.folders.contains($0.folder!) }.count)
            ForEach(noteStore.folders, id: \.self) { name in
                folderRow(.folder(name), name: name, icon: "folder", count: noteStore.notes.filter { $0.folder == name }.count)
                    .contextMenu {
                        Button("Rename…") { folderNameDraft = name; renameTarget = name }
                        Button("Delete…", role: .destructive) { deleteTarget = name }
                    }
            }
            folderRow(.trash, name: String(localized: "Trash"), icon: "trash", count: noteStore.trashedNotes.count)
            actionRow(title: String(localized: "New Folder"), icon: "folder.badge.plus") {
                folderNameDraft = ""
                newFolderShown = true
            }

            Divider()

            folderRow(.allBoards, name: String(localized: "All Boards"), icon: "square.grid.2x2",
                      count: boardStore.boards.reduce(0) { $0 + $1.cards.count })
            ForEach(boardStore.boards) { board in
                folderRow(.board(board.id), name: board.name, icon: "rectangle.split.3x1", count: board.cards.count)
                    .contextMenu {
                        Button("Rename…") { boardNameDraft = board.name; boardRenameTarget = board.id }
                        Button("Delete…", role: .destructive) { boardDeleteTarget = board.id }
                    }
            }
            actionRow(title: String(localized: "New Board"), icon: "plus.rectangle.on.folder") {
                boardNameDraft = ""
                newBoardShown = true
            }
        }
        .scrollContentBackground(.hidden)
        .navigationSplitViewColumnWidth(min: 150, ideal: 180)
    }

    /// "Boards" in the File menu, the menu-bar popover, and "Reveal in Board" all land here:
    /// they park a target on AppModel and open this window, which then selects it.
    private func consumeBoardReveal() {
        guard let reveal = appModel.pendingBoardReveal else { return }
        folderSelection = reveal.boardID.map { .board($0) } ?? .allBoards
        selectedCard = reveal.cardID
        appModel.pendingBoardReveal = nil
    }

    /// Sidebar row that performs an action instead of selecting something.
    private func actionRow(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label {
                    Text(title).lineLimit(1)
                } icon: {
                    Image(systemName: icon)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func folderRow(_ value: FolderSelection, name: String, icon: String, count: Int) -> some View {
        HStack {
            Label {
                Text(name).lineLimit(1)
            } icon: {
                Image(systemName: icon).foregroundStyle(MeatPadGlass.tint.gradient)
            }
            Spacer()
            Text("\(count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .tag(value)
    }

    // Bindings hoisted out of the modifier chain: this body carries enough chained alerts
    // that inline `Binding(get:set:)` closures push the type-checker past its budget.
    private var boardRenamePresented: Binding<Bool> {
        Binding(get: { boardRenameTarget != nil }, set: { if !$0 { boardRenameTarget = nil } })
    }

    private var boardDeletePresented: Binding<Bool> {
        Binding(get: { boardDeleteTarget != nil }, set: { if !$0 { boardDeleteTarget = nil } })
    }

    /// Pulled out of the `confirmationDialog` call: a trailing closure inside string
    /// interpolation blows past the type-checker's budget in that position.
    private var boardDeleteTitle: String {
        let name = boardStore.boards.first(where: { $0.id == boardDeleteTarget })?.name ?? ""
        return String(localized: "Delete “\(name)”? Its cards are deleted with it.")
    }

    private var selectedBoard: Board? {
        folderSelection.boardID.flatMap { id in boardStore.boards.first { $0.id == id } }
    }

    /// The selected card plus its owning board — the inspector needs both, and in the All
    /// Boards overview the card can come from any board.
    private var selectedCardRef: (board: Board, card: Card)? {
        guard let selectedCard else { return nil }
        for board in boardStore.boards {
            if let card = board.cards.first(where: { $0.id == selectedCard }) { return (board, card) }
        }
        return nil
    }

    private var boardColumns: some View {
        BoardColumnsView(store: boardStore, board: selectedBoard, selectedCard: $selectedCard)
            .navigationSplitViewColumnWidth(min: 420, ideal: 780)
    }

    @ViewBuilder
    private var boardDetail: some View {
        if let ref = selectedCardRef {
            CardInspectorView(store: boardStore, boardID: ref.board.id, card: ref.card) {
                selectedCard = nil
            }
        } else {
            Text("Select a card")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var noteList: some View {
        List(filtered, selection: $selection) { note in
            HStack(spacing: 9) {
                Image(systemName: "note.text")
                    .foregroundStyle(MeatPadGlass.tint.gradient)
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.title).lineLimit(1)
                    if let match = matchByID[note.id], !match.excerpt.isEmpty {
                        Text(Self.highlighted(match))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        RelativeTimeText(date: note.modified)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityIdentifier("note-row-\(note.id.uuidString)")
            .contextMenu {
                // Right-clicking a row inside a multi-selection acts on the whole selection;
                // right-clicking outside it acts on just that row (Finder behavior).
                let ids = contextTargets(for: note.id)
                if case .trash = folderSelection {
                    Button("Restore") { ids.forEach(restore) }
                    Button("Delete Permanently…", role: .destructive) { permanentDeleteTarget = Set(ids) }
                } else {
                    Button("Open in New Window") { ids.forEach(openInNewWindow) }
                    moveMenu(for: ids)
                    boardMenu(for: ids)
                    Button("Move to Trash", role: .destructive) { ids.forEach(trash) }
                }
            }
        }
        .onDeleteCommand(perform: deleteKeyPressed)
        .scrollContentBackground(.hidden)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        .overlay {
            if filtered.isEmpty {
                Text(query.isEmpty ? "No notes here" : "No matches")
                    .foregroundStyle(.secondary)
            }
        }
        .searchable(text: $query)
        .toolbar {
            ToolbarItem {
                Button {
                    newNote()
                } label: {
                    Label("New Note", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(folderSelection == .trash)
            }
        }
    }

    @ViewBuilder
    private func moveMenu(for ids: [UUID]) -> some View {
        // Disable the note's current folder only for a single-note move; a bulk move spans
        // folders, so every destination stays enabled (moving to a note's own folder is a
        // harmless no-op).
        let single = ids.count == 1 ? noteStore.notes.first(where: { $0.id == ids[0] }) : nil
        Menu("Move to") {
            Button("Notes") { ids.forEach { id in runFolderOp { try noteStore.move(id: id, to: nil) } } }
                .disabled(single != nil && single?.folder == nil)
            ForEach(noteStore.folders, id: \.self) { name in
                Button(name) { ids.forEach { id in runFolderOp { try noteStore.move(id: id, to: name) } } }
                    .disabled(single != nil && single?.folder == name)
            }
        }
    }

    /// Notes → board. A note that already has a card reveals it instead of making a second
    /// one: `card.noteID` is the only stored link, so one note has at most one card.
    @ViewBuilder
    private func boardMenu(for ids: [UUID]) -> some View {
        let boardStore = AppModel.shared.boardStore
        let existing = ids.count == 1 ? boardStore.card(forNote: ids[0]) : nil
        if let existing {
            Button("Reveal in Board") {
                folderSelection = .board(existing.board.id)
                selectedCard = existing.card.id
            }
        } else if !boardStore.boards.isEmpty {
            Menu("Send to Board") {
                ForEach(boardStore.boards) { board in
                    Button(board.name) { ids.forEach { sendToBoard($0, board: board) } }
                }
            }
        }
    }

    /// Creates a card in the board's first column, titled with the note and linked to it.
    private func sendToBoard(_ noteID: UUID, board: Board) {
        let boardStore = AppModel.shared.boardStore
        guard boardStore.card(forNote: noteID) == nil,
              let column = boardStore.columns(for: board).first,
              let note = noteStore.notes.first(where: { $0.id == noteID }),
              var card = try? boardStore.addCard(boardID: board.id, columnID: column.id, title: note.title) else { return }
        card.noteID = noteID
        try? boardStore.updateCard(boardID: board.id, card: card)
    }

    @ViewBuilder
    private var detail: some View {
        if selection.count == 1, let id = selection.first, noteStore.notes.contains(where: { $0.id == id }) {
            NoteDetailEditor(noteID: id) { openInNewWindow(id) }
                .id(id)
        } else if selection.count > 1 {
            placeholderPanel(
                // Inflection markup is only processed via AttributedString(localized:),
                // not String(localized:) — the latter shows the ^[…] markup literally.
                title: String(AttributedString(localized: "^[\(selection.count) note](inflect: true) selected").characters),
                subtitle: String(localized: "Select a single note to edit it here.")
            )
        } else {
            placeholderPanel(
                title: String(localized: "Select a note"),
                subtitle: String(localized: "Your notes stay ready when inspiration strikes.")
            )
        }
    }

    private func placeholderPanel(title: String, subtitle: String) -> some View {
        ZStack {
            AmbientGlassBackground()
            VStack(spacing: 12) {
                Image(systemName: "note.text")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(MeatPadGlass.tint.gradient)
                Text(title)
                    .font(.title3.weight(.medium))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(26)
            .glassPanel()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    /// New Note inside the browser: lands in the selected folder ("All Notes" → default),
    /// gets selected, and the detail editor takes over — no separate window (Apple Notes behavior).
    private func newNote() {
        guard let note = try? noteStore.createNote(in: folderSelection.noteFolder) else { return }
        selection = [note.id]
    }

    /// Ids a row's context-menu actions apply to: the whole selection when the row is part
    /// of a multi-selection, otherwise just the row itself.
    private func contextTargets(for id: UUID) -> [UUID] {
        (selection.contains(id) && selection.count > 1) ? Array(selection) : [id]
    }

    private func trashSelection() { Array(selection).forEach(trash) }
    private func restoreSelection() { Array(selection).forEach(restore) }
    private func openSelectionInNewWindow() { selection.forEach(openInNewWindow) }

    /// Plain ⌫/forward-delete on the list: trash the selection, or (in Trash) open the
    /// permanent-delete confirmation for it.
    private func deleteKeyPressed() {
        guard !selection.isEmpty else { return }
        if case .trash = folderSelection {
            permanentDeleteTarget = selection
        } else {
            trashSelection()
        }
    }

    /// Confirmation title for permanent delete: keep the note's own title for a single
    /// note, fall back to a pluralized count for a bulk delete.
    private var permanentDeleteTitle: String {
        guard let ids = permanentDeleteTarget else { return "" }
        if ids.count == 1, let id = ids.first,
           let title = noteStore.trashedNotes.first(where: { $0.id == id })?.title {
            return String(localized: "Delete “\(title)” permanently?")
        }
        // AttributedString(localized:) so the inflection markup actually inflects.
        return String(AttributedString(localized: "Delete ^[\(ids.count) note](inflect: true) permanently?").characters)
    }

    /// Opens a standalone note window for `id`. Safe to do while the same note is still
    /// selected in the browser: both surfaces resolve their view model through
    /// `EditorRegistry`, so this opens a second window onto the *same* `NoteEditorViewModel`
    /// rather than a competing copy — no flush-and-deselect handoff needed.
    private func openInNewWindow(_ id: UUID) {
        openWindow(value: id)
    }

    private func trash(_ id: UUID) {
        try? noteStore.trash(id: id)
        selection.remove(id)
    }

    /// Restores a trashed note; drops it from the selection since it leaves the trash list.
    private func restore(_ id: UUID) {
        try? noteStore.restore(id: id)
        selection.remove(id)
    }

    /// Jumps the newly-selected note's editor to its search hit, if any. The registry VM
    /// loads its text synchronously (see `NoteEditorViewModel.init`), and `reveal` is a
    /// one-shot target that survives until a not-yet-rendered `CodeEditor` consumes it —
    /// so this can fire immediately, before `NoteDetailEditor` itself has appeared.
    private func revealMatch(for noteID: UUID) {
        guard let range = matchByID[noteID]?.rangeInContents else { return }
        let vm = EditorRegistry.shared.noteViewModel(for: noteID)
        vm.reveal(range: Self.clamp(range, to: (vm.text as NSString).length))
    }

    /// Clamps a stale hit range (text edited/reloaded since the index produced it) into
    /// bounds. A range past the end collapses to a zero-length selection at the end —
    /// harmless scroll, per the brief.
    private static func clamp(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(range.location, 0), length)
        let len = min(max(range.length, 0), length - location)
        return NSRange(location: location, length: len)
    }

    /// Bolds `match.rangeInExcerpt` within `match.excerpt`. Same technique as
    /// `ProjectSearchView.highlighted(_:)`: attribute the `NSMutableAttributedString` in
    /// its native UTF-16 space (the range the index already computed) rather than
    /// converting to `String.Index` first.
    private static func highlighted(_ match: NoteSearchMatch) -> AttributedString {
        let mutable = NSMutableAttributedString(string: match.excerpt)
        if let range = match.rangeInExcerpt {
            let full = NSRange(location: 0, length: mutable.length)
            if range.location >= 0, range.location + range.length <= full.length {
                mutable.addAttribute(.font, value: NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .bold), range: range)
            }
        }
        return AttributedString(mutable)
    }

    private func runFolderOp(_ op: () throws -> Void) {
        do { try op() } catch {
            folderError = message(for: error)
        }
    }

    private func message(for error: Error) -> String {
        switch error as? NoteStoreError {
        case .folderExists(let name): return String(localized: "A folder named “\(name)” already exists.")
        case .invalidFolderName: return String(localized: "Folder names can’t be empty or “Notes”.")
        case .folderNotFound(let name): return String(localized: "Folder “\(name)” no longer exists.")
        default: return String(localized: "Something went wrong: \(error.localizedDescription)")
        }
    }
}

/// Actions the App-level menu commands (New Folder, Move to Trash/Restore, Open in New
/// Window) drive on the frontmost notes browser, published via `focusedSceneValue` — same
/// pattern as `\.projectViewModel`. `hasSelection`/`isTrash` gate the menu items' enabled
/// state and label.
struct NotesBrowserActions {
    var newFolder: () -> Void
    var trashSelection: () -> Void
    var restoreSelection: () -> Void
    var openSelectionInNewWindow: () -> Void
    var hasSelection: Bool
    var isTrash: Bool
}

private struct FocusedNotesBrowserKey: FocusedValueKey {
    typealias Value = NotesBrowserActions
}

extension FocusedValues {
    var notesBrowser: NotesBrowserActions? {
        get { self[FocusedNotesBrowserKey.self] }
        set { self[FocusedNotesBrowserKey.self] = newValue }
    }
}

/// Detail-pane editor for one note, selected from the browser sidebar. Mirrors
/// `NoteWindow`'s autosave wiring; `.id(selection)` on the call site forces a fresh
/// `@StateObject` wrapper whenever the sidebar selection changes, but the `EditorRegistry`
/// lookup inside `init` hands back the same live `NoteEditorViewModel` (no re-load) if the
/// note is already open elsewhere — e.g. in a standalone `NoteWindow`.
private struct NoteDetailEditor: View {
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var viewModel: NoteEditorViewModel
    @StateObject private var snippetController = SnippetController(library: AppModel.shared.snippetLibrary)
    @ObservedObject private var executor = AppModel.shared.commandExecutor
    private let onOpenInNewWindow: () -> Void

    init(noteID: UUID, onOpenInNewWindow: @escaping () -> Void) {
        self.onOpenInNewWindow = onOpenInNewWindow
        _viewModel = StateObject(wrappedValue: EditorRegistry.shared.noteViewModel(for: noteID))
    }

    /// Keyed on the per-pane snippet controller — the note VM is registry-shared
    /// across windows and would double-present the filter sheet.
    private var filterSheetShown: Binding<Bool> {
        Binding(
            get: { executor.filterContext?.hostID == AnyHashable(ObjectIdentifier(snippetController)) },
            set: { if !$0 { executor.filterContext = nil } }
        )
    }

    /// The executor's untrusted-command prompt, filtered to this pane the same way
    /// `filterSheetShown` is — keyed on `snippetController`, not the shared note view model.
    private var trustRequestForWindow: Binding<CommandTrustRequest?> {
        Binding(
            get: { executor.trustRequest?.context.hostID == AnyHashable(ObjectIdentifier(snippetController)) ? executor.trustRequest : nil },
            set: { if $0 == nil { executor.trustRequest = nil } }
        )
    }

    var body: some View {
        Group {
            if viewModel.exists {
                CodeEditor(
                    text: Binding(get: { viewModel.text }, set: viewModel.textDidChange),
                    language: viewModel.language,
                    theme: appModel.theme,
                    fontSize: appModel.fontSize,
                    softWrap: appModel.softWrap,
                    initialCursor: appModel.noteStore.notes.first(where: { $0.id == viewModel.noteID })?.cursor,
                    reveal: viewModel.revealTarget,
                    onRevealApplied: { viewModel.revealConsumed(token: $0) },
                    snippetController: snippetController,
                    onCursorChange: viewModel.cursorDidChange
                )
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    EditorStatusBar(
                        text: viewModel.text,
                        cursor: viewModel.cursor,
                        languageOverride: viewModel.languageOverride,
                        language: viewModel.language,
                        onSelectLanguage: viewModel.setLanguage
                    )
                }
            } else {
                Text("This note was deleted.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .focusedSceneValue(\.snippetInsertion, SnippetInsertion(languageID: viewModel.language?.id, insert: { snippetController.insert($0) }))
        .focusedSceneValue(\.editorCommandContext, EditorCommandContext.make(
            hostID: ObjectIdentifier(snippetController),
            panelCapable: false,
            textView: snippetController.textView,
            languageID: viewModel.language?.id,
            displayName: viewModel.title
        ))
        .sheet(isPresented: filterSheetShown) {
            if let context = executor.filterContext {
                FilterCommandSheet(context: context, onDismiss: { executor.filterContext = nil })
            }
        }
        .sheet(item: trustRequestForWindow) { request in
            CommandTrustSheet(
                request: request,
                onCancel: { executor.trustRequest = nil },
                onRunOnce: {
                    executor.trustRequest = nil
                    executor.runOnce(request.command, context: request.context)
                },
                onTrustAndRun: {
                    executor.trustRequest = nil
                    executor.trustAndRun(request.command, context: request.context)
                }
            )
        }
        .toolbar {
            ToolbarItem {
                Button("Open in New Window", action: onOpenInNewWindow)
            }
        }
        .onAppear { viewModel.load() }
        .onDisappear { viewModel.flush() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            viewModel.flush()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            viewModel.flush()
        }
        .focusedValue(\.noteEditor, viewModel)
    }
}
