import Combine
import Foundation
import SwiftUI
import MeatPadKit

/// App-wide state: the note store and the active theme (persisted across launches as a
/// theme id string in UserDefaults).
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let noteStore: NoteStore
    /// User + builtin snippets, backed by `~/Library/Application Support/MeatPad/Snippets`
    /// (sibling of Notes). One instance shared by every editor and the settings pane.
    let snippetLibrary: SnippetLibrary
    /// Saved shell commands, backed by the sibling `Commands` directory.
    let commandStore: CommandStore
    /// App-wide shell command runner (one command at a time), shared by the Commands
    /// menu, the filter sheet, and the output panels.
    let commandExecutor = CommandExecutor()
    @Published var theme: Theme {
        didSet { UserDefaults.standard.set(theme.id, forKey: Self.themeDefaultsKey) }
    }
    @Published var fontSize: CGFloat {
        didSet { UserDefaults.standard.set(Double(fontSize), forKey: Self.fontSizeDefaultsKey) }
    }
    @Published var softWrap: Bool {
        didSet { UserDefaults.standard.set(softWrap, forKey: Self.softWrapDefaultsKey) }
    }
    /// MRU list of project folder paths, most recent first, capped at 10 — backs the
    /// File ▸ Open Recent submenu.
    @Published private(set) var recentProjectPaths: [String] {
        didSet { UserDefaults.standard.set(recentProjectPaths, forKey: Self.recentProjectsDefaultsKey) }
    }

    /// Bridge to SwiftUI's `openWindow` action, captured once from `MeatPadApp.body`
    /// (which runs before AppKit's `applicationDidFinishLaunching`) so the
    /// `NSApplicationDelegateAdaptor` can open windows during launch restore, where no
    /// SwiftUI environment is otherwise reachable.
    var openWindowAction: OpenWindowAction?

    /// Set just before opening a project window when the user picked a *file* (Cmd+O):
    /// the parent opens as the project and the new `ProjectViewModel` consumes this to
    /// pre-open the file as a tab. Plain var (consumed once, imperatively).
    var pendingFileOpen: URL?

    /// Saved tabs/selection for a project window about to be reopened by session
    /// restore, keyed by standardized root URL. `ProjectViewModel.init` consumes (and
    /// removes) its own entry, same one-shot pattern as `pendingFileOpen`.
    var pendingProjectSessions: [URL: ProjectSession] = [:]

    private var openNoteIDs: [UUID] = []
    private var browserOpen = false
    /// Open project windows, keyed by instance identity (not root — the same folder can
    /// be open in two windows, and each needs its own tabs/selection tracked). Combine
    /// sinks re-schedule the session write whenever a tracked VM's tabs/selection change.
    private var projectViewModels: [ObjectIdentifier: ProjectViewModel] = [:]
    private var projectViewModelSinks: [ObjectIdentifier: AnyCancellable] = [:]
    private let sessionDebouncer = Debouncer(delay: 0.5)

    private static let themeDefaultsKey = "themeID"
    private static let fontSizeDefaultsKey = "editorFontSize"
    private static let softWrapDefaultsKey = "softWrap"
    private static let recentProjectsDefaultsKey = "recentProjectPaths"

    /// Sibling of the Notes directory (not inside it, so it's never mistaken for a note).
    private static var sessionURL: URL {
        NoteStore.defaultRoot().deletingLastPathComponent().appendingPathComponent("session.json")
    }

    private init() {
        do {
            noteStore = try NoteStore(rootURL: NoteStore.defaultRoot())
        } catch {
            fatalError("MeatPad couldn't set up its notes folder at \(NoteStore.defaultRoot().path): \(error)")
        }
        let snippetsDir = NoteStore.defaultRoot().deletingLastPathComponent().appendingPathComponent("Snippets", isDirectory: true)
        snippetLibrary = SnippetLibrary(userDirectory: snippetsDir)
        let commandsDir = NoteStore.defaultRoot().deletingLastPathComponent().appendingPathComponent("Commands", isDirectory: true)
        commandStore = CommandStore(directory: commandsDir)
        let savedID = UserDefaults.standard.string(forKey: Self.themeDefaultsKey)
        theme = savedID.flatMap { id in BuiltinThemes.all.first { $0.id == id } } ?? BuiltinThemes.defaultDark

        let savedFontSize = UserDefaults.standard.object(forKey: Self.fontSizeDefaultsKey) as? Double
        fontSize = savedFontSize.map { CGFloat($0) } ?? 13

        let savedSoftWrap = UserDefaults.standard.object(forKey: Self.softWrapDefaultsKey) as? Bool
        softWrap = savedSoftWrap ?? true

        recentProjectPaths = UserDefaults.standard.stringArray(forKey: Self.recentProjectsDefaultsKey) ?? []
    }

    /// Shell-command "New Note" output mode: create a note holding `contents` and open
    /// its window. Best-effort — a store failure just drops the output note.
    func openNewNote(withContents contents: String) {
        guard let note = try? noteStore.createNote() else { return }
        try? noteStore.save(id: note.id, contents: contents, cursor: 0)
        openWindowAction?(value: note.id)
    }

    // MARK: - Recent projects

    /// Moves `url` to the front of the MRU list (adding it if new), capped at 10.
    func recordRecentProject(_ url: URL) {
        var paths = recentProjectPaths
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        recentProjectPaths = Array(paths.prefix(10))
    }

    func clearRecentProjects() {
        recentProjectPaths = []
    }

    // MARK: - Session tracking

    func noteWindowDidAppear(_ id: UUID) {
        if !openNoteIDs.contains(id) { openNoteIDs.append(id) }
        scheduleSessionSave()
    }

    func noteWindowDidDisappear(_ id: UUID) {
        openNoteIDs.removeAll { $0 == id }
        scheduleSessionSave()
    }

    func browserWindowDidAppear() {
        browserOpen = true
        scheduleSessionSave()
    }

    func browserWindowDidDisappear() {
        browserOpen = false
        scheduleSessionSave()
    }

    /// Registers a project window so its tabs/selection are captured on every session
    /// write. Sinks the VM's `objectWillChange` so tab open/close/select changes
    /// schedule a debounced save without any per-action wiring at the call sites.
    func projectWindowDidAppear(_ viewModel: ProjectViewModel) {
        let id = ObjectIdentifier(viewModel)
        guard projectViewModels[id] == nil else { return }
        projectViewModels[id] = viewModel
        projectViewModelSinks[id] = viewModel.objectWillChange.sink { [weak self] _ in
            self?.scheduleSessionSave()
        }
        scheduleSessionSave()
    }

    func projectWindowDidDisappear(_ viewModel: ProjectViewModel) {
        let id = ObjectIdentifier(viewModel)
        projectViewModels.removeValue(forKey: id)
        projectViewModelSinks.removeValue(forKey: id)
        scheduleSessionSave()
    }

    /// Called from `applicationDidFinishLaunching`: reopens whatever was open at last
    /// quit, dropping ids for notes and project roots that no longer exist on disk.
    /// Falls back to one fresh note when there's nothing valid to restore, so launch
    /// never shows zero windows. Duplicate saved roots collapse to one restored window —
    /// `WindowGroup(for:)` dedups by value.
    func restoreSession() {
        guard let openWindowAction else { return }
        let state = SessionState.load(from: Self.sessionURL)
        let idsToRestore = (state?.openNoteIDs ?? []).filter { id in noteStore.notes.contains { $0.id == id } }
        let projectsToRestore = (state?.openProjects ?? []).filter { session in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: session.root, isDirectory: &isDirectory) && isDirectory.boolValue
        }

        guard !idsToRestore.isEmpty || state?.browserOpen == true || !projectsToRestore.isEmpty else {
            if let note = try? noteStore.createNote() {
                openWindowAction(value: note.id)
            }
            return
        }

        for id in idsToRestore { openWindowAction(value: id) }
        if state?.browserOpen == true { openWindowAction(id: "all-notes") }
        for session in projectsToRestore {
            let rootURL = URL(fileURLWithPath: session.root).standardizedFileURL
            pendingProjectSessions[rootURL] = session
            openWindowAction(value: rootURL)
        }
    }

    /// Immediate, non-debounced write — used on `applicationWillTerminate` so the last
    /// window open/close right before quit isn't lost to the pending debounce.
    func saveSessionNow() {
        sessionDebouncer.cancel()
        let openProjects = projectViewModels.values.map { vm in
            ProjectSession(root: vm.root.path, openTabs: vm.tabs.map(\.path), selectedTab: vm.selectedTab?.path)
        }
        try? SessionState(openNoteIDs: openNoteIDs, browserOpen: browserOpen, openProjects: openProjects)
            .save(to: Self.sessionURL)
    }

    private func scheduleSessionSave() {
        sessionDebouncer.call { [weak self] in self?.saveSessionNow() }
    }
}
