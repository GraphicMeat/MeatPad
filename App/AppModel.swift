import AppKit
import Combine
import Foundation
import SwiftUI
import MeatPadKit
import Sparkle

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
    /// Saved keystroke macros, backed by the sibling `Macros` directory.
    let macroStore: MacroStore
    /// Kanban boards, backed by the sibling `Boards` directory. One board per project.
    let boardStore: BoardStore
    /// User themes, backed by the sibling `Themes` directory. `BuiltinThemes.all` is
    /// always available through it too (see `ThemeStore.allThemes`).
    let themeStore: ThemeStore
    /// App-wide shell command runner (one command at a time), shared by the Commands
    /// menu, the filter sheet, and the output panels.
    let commandExecutor = CommandExecutor()
    /// Keystroke recorder/player, shared by the Commands menu and the editor's key tap.
    let macroController = MacroController()
    /// Sparkle's updater, owned app-wide so both the menu command and any future settings
    /// UI share one instance. DEBUG builds start it suspended (`startingUpdater: false`) so
    /// dev runs never hit the feed or prompt to install over a debug build.
    let updaterController: SPUStandardUpdaterController
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
    /// Optional one-shot scroll target for `pendingFileOpen`, in the *target file's* own
    /// UTF-16 coordinates — set alongside it by Go to Definition (0.7 LSP plan Task 4) when
    /// the definition lives outside the current project root, so the new window's
    /// `ProjectViewModel` can jump straight to the line instead of just opening the file.
    /// `nil` (the Cmd+O path never sets it) means "just open the tab, no reveal."
    var pendingFileOpenReveal: NSRange?

    /// Saved tabs/selection for a project window about to be reopened by session
    /// restore, keyed by standardized root URL. `ProjectViewModel.init` consumes (and
    /// removes) its own entry, same one-shot pattern as `pendingFileOpen`.
    var pendingProjectSessions: [URL: ProjectSession] = [:]

    /// Set by `PrivacySettingsView.confirmDeleteAll()` immediately before recycling the
    /// storage root, so the `NSApp.terminate` in its completion handler doesn't race
    /// `applicationWillTerminate` → `saveSessionNow()` into rewriting session.json (with
    /// open note ids and project paths) back into the just-emptied storage — which would
    /// both defeat the fresh-slate promise and leak paths post-erase.
    var isDeletingAllData = false

    private var openNoteIDs: [UUID] = []
    private var browserOpen = false
    private var boardsOpen = false
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

    /// The storage base (`~/Library/Application Support/MeatPad`, or the override root),
    /// resolved once in `init` and reused by every use site — never re-derived from
    /// `NoteStore.defaultRoot()`, which would re-read the override default and could
    /// disagree if the override key changes during the app's lifetime.
    private let storageBase: URL

    /// Sibling of the Notes directory (not inside it, so it's never mistaken for a note).
    private var sessionURL: URL {
        storageBase.appendingPathComponent("session.json")
    }

    /// The resolved storage root's filesystem path — shown verbatim in the first-run
    /// intro (and, from 0.8 Task 5, Settings → Privacy). Same `storageBase` every other
    /// sibling directory derives from, so this is always the actual on-disk location,
    /// override or not.
    var storageRootPath: String { storageBase.path }

    private init() {
        #if DEBUG
        let startUpdater = false
        #else
        let startUpdater = true
        #endif
        updaterController = SPUStandardUpdaterController(
            startingUpdater: startUpdater, updaterDelegate: nil, userDriverDelegate: nil
        )

        // Resolved once so Notes + all five siblings agree even if defaultRoot() picks up
        // a storage-root override mid-init (defaults reads are otherwise not atomic across
        // the repeated calls this used to make).
        let notesRoot = NoteStore.defaultRoot()
        do {
            noteStore = try NoteStore(rootURL: notesRoot)
        } catch {
            fatalError("MeatPad couldn't set up its notes folder at \(notesRoot.path): \(error)")
        }
        let base = notesRoot.deletingLastPathComponent()
        storageBase = base
        let snippetsDir = base.appendingPathComponent("Snippets", isDirectory: true)
        snippetLibrary = SnippetLibrary(userDirectory: snippetsDir)
        let commandsDir = base.appendingPathComponent("Commands", isDirectory: true)
        commandStore = CommandStore(directory: commandsDir)
        let macrosDir = base.appendingPathComponent("Macros", isDirectory: true)
        macroStore = MacroStore(directory: macrosDir)
        let boardsDir = base.appendingPathComponent("Boards", isDirectory: true)
        do {
            // Default column names are seeded localized here — MeatPadKit ships no catalog.
            boardStore = try BoardStore(
                rootURL: boardsDir,
                defaultColumnNames: (String(localized: "Todo"), String(localized: "In Progress"), String(localized: "Done"))
            )
        } catch {
            fatalError("MeatPad couldn't set up its boards folder at \(boardsDir.path): \(error)")
        }
        let themesDir = base.appendingPathComponent("Themes", isDirectory: true)
        let themeStore = ThemeStore(directory: themesDir)
        self.themeStore = themeStore
        let savedID = UserDefaults.standard.string(forKey: Self.themeDefaultsKey)
        theme = savedID.flatMap { themeStore.theme(id: $0) } ?? BuiltinThemes.defaultDark

        let savedFontSize = UserDefaults.standard.object(forKey: Self.fontSizeDefaultsKey) as? Double
        fontSize = savedFontSize.map { CGFloat($0) } ?? 13

        let savedSoftWrap = UserDefaults.standard.object(forKey: Self.softWrapDefaultsKey) as? Bool
        softWrap = savedSoftWrap ?? true

        recentProjectPaths = UserDefaults.standard.stringArray(forKey: Self.recentProjectsDefaultsKey) ?? []

        DueNotifier.shared.start(store: boardStore)
    }

    /// Shell-command "New Note" output mode: create a note holding `contents` and open
    /// its window. Best-effort — a store failure just drops the output note.
    func openNewNote(withContents contents: String) {
        guard let note = try? noteStore.createNote() else { return }
        try? noteStore.save(id: note.id, contents: contents, cursor: 0)
        openWindowAction?(value: note.id)
    }

    // MARK: - Open project

    /// File ▸ Open… (and the Dock menu). Directory → open as a project. File → open the
    /// file's parent folder as the project and pre-open the file as a tab (via
    /// `pendingFileOpen`, consumed by the new `ProjectViewModel`). Shared by the File menu
    /// and the Dock menu so both take the identical path.
    func openProjectPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            if url.hasDirectoryPath {
                self.openProject(url)
            } else {
                self.pendingFileOpen = url
                self.openProject(url.deletingLastPathComponent())
            }
        }
    }

    func openProject(_ url: URL) {
        openWindowAction?(value: url)
        recordRecentProject(url)
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

    func boardWindowDidAppear() {
        boardsOpen = true
        scheduleSessionSave()
    }

    func boardWindowDidDisappear() {
        boardsOpen = false
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

    /// True when at least one project window is open — `applicationShouldTerminate` uses
    /// this to decide whether quit needs to wait on LSP shutdown at all.
    var hasOpenProjectWindows: Bool { !projectViewModels.isEmpty }

    /// Quit doesn't close each project window individually (`applicationShouldTerminate`
    /// answers `.terminateNow`/`.terminateLater` itself), so `ProjectWindowCloseGuard
    /// .windowShouldClose` never runs and never gets a chance to shut its project's
    /// language servers down. Called from `applicationShouldTerminate` to give every
    /// still-open project's servers the same graceful exit a normal window close would
    /// have sent — and, unlike the old fire-and-forget `shutdown()`, actually awaited
    /// before the app is allowed to exit. macOS does not kill child processes when the
    /// parent quits, and the LSP handle's own self-exit-on-parent-death backstop has been
    /// observed to leak in practice (live-quit testing, LSP-t4), so detached shutdown
    /// Tasks that nobody waits on can leave orphaned server processes behind. Every
    /// project's shutdown runs in parallel via `TaskGroup` so N open projects don't
    /// serialize into N*timeout.
    func shutdownAllProjectLSPManagersAndWait(timeout: TimeInterval = 3) async {
        await withTaskGroup(of: Void.self) { group in
            for viewModel in projectViewModels.values {
                group.addTask {
                    await viewModel.lspManager.shutdownAndWait(timeout: timeout)
                }
            }
        }
    }

    /// Called from `applicationDidFinishLaunching`: reopens whatever was open at last
    /// quit, dropping ids for notes and project roots that no longer exist on disk.
    /// Falls back to one fresh note when there's nothing valid to restore, so launch
    /// never shows zero windows. Duplicate saved roots collapse to one restored window —
    /// `WindowGroup(for:)` dedups by value.
    func restoreSession() {
        guard let openWindowAction else { return }
        let state = SessionState.load(from: sessionURL)
        let idsToRestore = (state?.openNoteIDs ?? []).filter { id in noteStore.notes.contains { $0.id == id } }
        let projectsToRestore = (state?.openProjects ?? []).filter { session in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: session.root, isDirectory: &isDirectory) && isDirectory.boolValue
        }

        guard !idsToRestore.isEmpty || state?.browserOpen == true || !projectsToRestore.isEmpty
                || state?.boardsOpen == true else {
            if let note = try? noteStore.createNote() {
                openWindowAction(value: note.id)
            }
            return
        }

        for id in idsToRestore { openWindowAction(value: id) }
        if state?.browserOpen == true { openWindowAction(id: "all-notes") }
        if state?.boardsOpen == true { openWindowAction(id: BoardWindow.windowID) }
        for session in projectsToRestore {
            let rootURL = URL(fileURLWithPath: session.root).standardizedFileURL
            pendingProjectSessions[rootURL] = session
            openWindowAction(value: rootURL)
        }
    }

    /// Immediate, non-debounced write — used on `applicationWillTerminate` so the last
    /// window open/close right before quit isn't lost to the pending debounce.
    func saveSessionNow() {
        guard !isDeletingAllData else { return }
        sessionDebouncer.cancel()
        let openProjects = projectViewModels.values.map { vm in
            ProjectSession(root: vm.root.path, openTabs: vm.tabs.map(\.path), selectedTab: vm.selectedTab?.path)
        }
        try? SessionState(openNoteIDs: openNoteIDs, browserOpen: browserOpen, openProjects: openProjects, boardsOpen: boardsOpen)
            .save(to: sessionURL)
    }

    private func scheduleSessionSave() {
        sessionDebouncer.call { [weak self] in self?.saveSessionNow() }
    }
}
