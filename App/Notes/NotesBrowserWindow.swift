import SwiftUI
import AppKit
import MeatPadKit

/// Which folder the browser is showing. Raw-string encoded for @SceneStorage.
enum FolderSelection: Hashable, RawRepresentable {
    case all
    case defaultFolder          // the implicit "Notes" folder (Note.folder == nil)
    case folder(String)

    var rawValue: String {
        switch self {
        case .all: return "all"
        case .defaultFolder: return "default"
        case .folder(let name): return "f:\(name)"
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "all": self = .all
        case "default": self = .defaultFolder
        default:
            guard rawValue.hasPrefix("f:") else { return nil }
            self = .folder(String(rawValue.dropFirst(2)))
        }
    }

    /// The value new/moved notes get in this context: "All Notes" creates into the default folder.
    var noteFolder: String? {
        if case .folder(let name) = self { return name }
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
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""
    @State private var selection: UUID?
    @SceneStorage("notesBrowser.folder") private var folderSelection: FolderSelection = .all

    // New Folder / Rename alerts.
    @State private var folderNameDraft = ""
    @State private var newFolderShown = false
    @State private var renameTarget: String?
    @State private var deleteTarget: String?
    @State private var folderError: String?

    private var filtered: [Note] {
        var notes = noteStore.notes
        switch folderSelection {
        case .all: break
        case .defaultFolder:
            // Unknown-folder notes (folder name absent from folders.json) fall back here.
            notes = notes.filter { $0.folder == nil || !noteStore.folders.contains($0.folder!) }
        case .folder(let name):
            notes = notes.filter { $0.folder == name }
        }
        guard !query.isEmpty else { return notes }
        return notes.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationSplitView {
            folderSidebar
        } content: {
            noteList
        } detail: {
            detail
        }
        .background { AmbientGlassBackground() }
        .frame(minWidth: 860, minHeight: 480)
        .onAppear { AppModel.shared.browserWindowDidAppear() }
        .onDisappear { AppModel.shared.browserWindowDidDisappear() }
        .onChange(of: folderSelection) { _, _ in selection = nil }
        .alert("New Folder", isPresented: $newFolderShown) {
            TextField("Name", text: $folderNameDraft)
            Button("Create") { runFolderOp { try noteStore.createFolder(folderNameDraft) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Folder", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $folderNameDraft)
            Button("Rename") {
                if let old = renameTarget {
                    let new = folderNameDraft
                    runFolderOp { try noteStore.renameFolder(old, to: new) }
                    if case .folder(old) = folderSelection { folderSelection = .folder(new) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete “\(deleteTarget ?? "")”? Its notes move to the trash.",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Folder", role: .destructive) {
                if let name = deleteTarget {
                    runFolderOp { try noteStore.deleteFolder(name) }
                    if case .folder(name) = folderSelection { folderSelection = .all }
                }
            }
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
            folderRow(.all, name: "All Notes", icon: "tray.full", count: noteStore.notes.count)
            folderRow(.defaultFolder, name: "Notes", icon: "folder", count: noteStore.notes.filter { $0.folder == nil || !noteStore.folders.contains($0.folder!) }.count)
            ForEach(noteStore.folders, id: \.self) { name in
                folderRow(.folder(name), name: name, icon: "folder", count: noteStore.notes.filter { $0.folder == name }.count)
                    .contextMenu {
                        Button("Rename…") { folderNameDraft = name; renameTarget = name }
                        Button("Delete…", role: .destructive) { deleteTarget = name }
                    }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationSplitViewColumnWidth(min: 150, ideal: 180)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    folderNameDraft = ""
                    newFolderShown = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(10)
        }
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

    @ViewBuilder
    private var noteList: some View {
        List(filtered, selection: $selection) { note in
            HStack(spacing: 9) {
                Image(systemName: "note.text")
                    .foregroundStyle(MeatPadGlass.tint.gradient)
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.title).lineLimit(1)
                    Text(note.modified, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contextMenu {
                Button("Open in New Window") { openInNewWindow(note.id) }
                moveMenu(for: note)
                Button("Move to Trash", role: .destructive) { trash(note.id) }
            }
        }
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
            }
        }
    }

    @ViewBuilder
    private func moveMenu(for note: Note) -> some View {
        Menu("Move to") {
            Button("Notes") { runFolderOp { try noteStore.move(id: note.id, to: nil) } }
                .disabled(note.folder == nil)
            ForEach(noteStore.folders, id: \.self) { name in
                Button(name) { runFolderOp { try noteStore.move(id: note.id, to: name) } }
                    .disabled(note.folder == name)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selection, noteStore.notes.contains(where: { $0.id == selection }) {
            NoteDetailEditor(noteID: selection) { openInNewWindow(selection) }
                .id(selection)
        } else {
            ZStack {
                AmbientGlassBackground()
                VStack(spacing: 12) {
                    Image(systemName: "note.text")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(MeatPadGlass.tint.gradient)
                    Text("Select a note")
                        .font(.title3.weight(.medium))
                    Text("Your notes stay ready when inspiration strikes.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(26)
                .glassPanel()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Actions

    /// New Note inside the browser: lands in the selected folder ("All Notes" → default),
    /// gets selected, and the detail editor takes over — no separate window (Apple Notes behavior).
    private func newNote() {
        guard let note = try? noteStore.createNote(in: folderSelection.noteFolder) else { return }
        selection = note.id
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
        if selection == id { selection = nil }
    }

    private func runFolderOp(_ op: () throws -> Void) {
        do { try op() } catch {
            folderError = message(for: error)
        }
    }

    private func message(for error: Error) -> String {
        switch error as? NoteStoreError {
        case .folderExists(let name): return "A folder named “\(name)” already exists."
        case .invalidFolderName: return "Folder names can’t be empty or “Notes”."
        case .folderNotFound(let name): return "Folder “\(name)” no longer exists."
        default: return "Something went wrong: \(error.localizedDescription)"
        }
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
                    snippetController: snippetController,
                    onCursorChange: viewModel.cursorDidChange
                )
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
