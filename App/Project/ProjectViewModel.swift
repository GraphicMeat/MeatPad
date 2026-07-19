import Foundation
import AppKit
import MeatPadKit
import ProcessEnv
import LanguageServerProtocol

/// Owns one project window's state: the live file tree (rescanned on any change under
/// `root`), the open tabs, and the save/close/external-change flows over them. The file
/// buffers themselves live in `EditorRegistry` (canonical per-URL VMs); this coordinates
/// which are open and drives the dialogs that only apply to files (notes stay silent).
@MainActor
final class ProjectViewModel: ObservableObject {
    /// Banner shown over the editor when disk diverges from the open buffer.
    enum Banner: Equatable { case changedOnDisk, deleted }

    /// Project-scoped "language server isn't installed" notice — parallel to `banners`
    /// (which is per-URL), since a missing server is a project-wide fact about a
    /// language, not a fact about any one open file.
    struct LSPBannerState: Equatable {
        let languageID: String
        let languageName: String
        let installHint: String
    }

    /// Which content the sidebar shows: the live file tree, Cmd+Shift+F project search, or
    /// Find References results (Task 5).
    enum SidebarMode: Hashable { case files, search, references }

    /// Language IDs `LSPServerDetector` knows about — the only ones that ever touch
    /// `lspManager`. Derived from the kit's own catalog instead of a second hardcoded
    /// list here, so a language added to the kit's catalog is picked up automatically.
    private static let lspKnownLanguageIDs = Set(LSPServerDetector.knownServers.flatMap(\.languageIDs))

    let root: URL
    @Published var tree: TreeNode
    @Published var tabs: [URL] = []
    @Published var selectedTab: URL?
    /// At-most-one-visible per tab; the host shows `banners[selectedTab]`.
    @Published var banners: [URL: Banner] = [:]
    /// Per-project language server manager, detected once at init. Lazily starts a
    /// server the first time a file of that language opens; torn down when the project
    /// window actually closes (`ProjectWindowCloseGuard.windowShouldClose`).
    let lspManager: LSPProjectManager
    /// Mirrors `lspManager.statusByLanguage`, republished so SwiftUI observes it (the
    /// manager's own property isn't `@Published`).
    @Published private(set) var lspStatusByLanguage: [String: LSPServerStatus] = [:]
    /// Latest diagnostics per open document, keyed by URI string (`url.absoluteString`,
    /// matching `LSPProjectManager`'s own URI keying). This VM is the single subscriber to
    /// `lspManager.onPublishDiagnostics` — see that property's doc comment — and republishes
    /// per-URI so `DocumentHostView` can hand each `CodeEditor` only its own file's slice.
    @Published private(set) var diagnosticsByURI: [String: [Diagnostic]] = [:]
    /// Single project-level missing-server notice — see `LSPBannerState`.
    @Published var lspBanner: LSPBannerState?
    /// Languages a missing-server banner has already been shown for this session — shown
    /// at most once per language per project, whether or not the user dismissed it.
    ///
    /// ponytail: `lspBanner` is a single slot, so two different missing languages opened
    /// back-to-back before the first is dismissed means the second replaces the first
    /// (both still get marked "shown", so neither retriggers). A queue would cover the
    /// rare multi-missing-language case; not worth it for one banner at a time.
    private var lspBannerShownLanguages: Set<String> = []
    /// Cmd+T quick-open overlay, toggled by the app-level command.
    @Published var quickOpenVisible = false
    @Published var sidebarMode: SidebarMode = .files
    /// Find References results (Task 5) — sidebar's `.references` mode content. Overwritten
    /// wholesale by each new request, same one-slot-no-history shape as `referencesResults`'
    /// nearest analogue, `ProjectSearchViewModel.results`.
    @Published private(set) var referencesResults: [FileMatchGroup] = []
    /// Document Symbols (Task 5) quick-open-style overlay, parallel to `quickOpenVisible`.
    @Published var documentSymbolsVisible = false
    @Published private(set) var documentSymbolResults: [DocumentSymbols.Item] = []
    /// One-shot scroll+select for the currently selected tab's `CodeEditor` (search-result
    /// jumps). Cleared right after being read so switching away and back to the same tab
    /// later never replays a stale selection.
    @Published private(set) var revealTarget: RevealTarget?

    /// Set via `attach(window:)` so the dirty-close/save sheets attach to this window.
    weak var window: NSWindow?
    /// `NSWindow.delegate` is weak — this keeps the close-guard proxy alive.
    private var closeGuard: ProjectWindowCloseGuard?

    /// URLs where the user chose "Keep Mine" for the current on-disk revision — suppresses
    /// re-nagging on every window-key until the doc is next saved/reverted (mtime resets).
    private var dismissedChanges: Set<URL> = []

    // Not explicitly stopped in a deinit: DirectoryWatcher's own nonisolated deinit
    // tears down the FSEventStream directly when this VM (and its last strong
    // reference to the watcher) goes away.
    private var watcher: DirectoryWatcher?
    /// The in-flight full scan kicked off by `rescan()`. Cancelled and replaced on every
    /// call so a burst of FS events can't pile up redundant scans.
    private var scanTask: Task<Void, Never>?

    /// Project-wide identifier index for completion (Task 4 wires it into
    /// `CompletionController`). Rebuilt off the full tree after every `rescan()` —
    /// never off the shallow initial tree, which has placeholder children.
    let symbolIndex = ProjectSymbolIndex()
    /// The in-flight index build kicked off after a rescan. Cancelled/replaced the same
    /// way as `scanTask`; `ProjectSymbolIndex.build` is itself supersede-safe (generation
    /// check), so this is belt-and-suspenders against piling up redundant builds.
    private var indexTask: Task<Void, Never>?

    init(root: URL) {
        self.root = root
        // GUI apps launched from Finder don't inherit the login shell's PATH (the LSP
        // plan's "CRITICAL gotcha"); `ProcessInfo.userEnvironment` (ChimeHQ's ProcessEnv,
        // already a transitive build dependency via MeatPadKit) reconstructs it by
        // shelling out to the user's shell once. Detection AND every server process
        // launch use this same resolved environment, never the app's own.
        let userEnvironment = ProcessInfo.processInfo.userEnvironment
        let detected = LSPServerDetector.detect(userEnvironment: userEnvironment)
        self.lspManager = LSPProjectManager(projectRoot: root, detected: detected, userEnvironment: userEnvironment)
        // Shows the window instantly with just the top level, then `rescan()` below
        // fills in the full tree off the main thread — opening a big repo no longer
        // blocks the window from appearing.
        self.tree = ProjectScanner.scanShallow(root: root)
        self.watcher = DirectoryWatcher(root: root) { [weak self] in
            self?.rescan()
        }
        rescan()
        lspManager.onStatusChange = { [weak self] statuses in
            self?.lspStatusByLanguage = statuses
        }
        lspManager.onPublishDiagnostics = { [weak self] uri, diagnostics in
            self?.diagnosticsByURI[uri] = diagnostics
        }
        // Session restore: AppModel stashed this root's saved tabs/selection keyed by
        // standardized URL just before calling openWindow. Consume once; drop tabs for
        // files that vanished since the session was saved, falling back to the first
        // surviving tab when the saved selection is gone too.
        if let session = AppModel.shared.pendingProjectSessions.removeValue(forKey: root.standardizedFileURL) {
            let restoredTabs = session.openTabs
                .map { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            tabs = restoredTabs
            let savedSelection = session.selectedTab.map { URL(fileURLWithPath: $0) }
            selectedTab = (savedSelection.flatMap { restoredTabs.contains($0) ? $0 : nil }) ?? restoredTabs.first
        } else if let pending = AppModel.shared.pendingFileOpen,
           // Task 6 leftover: Cmd+O on a file opens its parent as a project and
           // pre-opens the file as a tab. AppModel stashes the file; consume it if it
           // lives under this root.
           pending.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL {
            tabs = [pending]
            selectedTab = pending
            AppModel.shared.pendingFileOpen = nil
            if let range = AppModel.shared.pendingFileOpenReveal {
                revealTarget = RevealTarget(token: UUID(), range: range)
                AppModel.shared.pendingFileOpenReveal = nil
            }
        }
        // Restored/pre-opened tabs above bypass `open(file:)` (they assign `tabs`
        // directly to preserve order/selection), so notify the LSP manager for them here.
        for url in tabs { notifyLSPDocumentOpened(url) }
    }

    /// Runs a full recursive scan off the main actor and swaps it in when done. Cancels
    /// any scan already in flight first, so the watcher firing repeatedly during a big
    /// FS change (e.g. a git checkout) doesn't queue up redundant work. Once the new tree
    /// lands, kicks off a symbol-index rebuild from it (never from the shallow initial
    /// tree, which has placeholder children).
    func rescan() {
        scanTask?.cancel()
        let root = root
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let scanned = ProjectScanner.scan(root: root)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.tree = scanned
                self.rebuildSymbolIndex()
            }
        }
    }

    /// Rebuilds the project symbol index from the current (full) tree. Called after every
    /// `rescan()` completes — including the one the FSEvents watcher triggers on any disk
    /// change under `root`.
    //
    // ponytail: DirectoryWatcher's callback here is a bare debounced "something changed"
    // signal (no per-path payload), so a disk change anywhere forces a full re-tokenize of
    // every file rather than an incremental `updateFile`/`removeFile` on just the paths
    // that moved. `ProjectSymbolIndex.build` is generation-guarded (a superseding call
    // always wins), so a burst of watcher events during e.g. a git checkout just cancels
    // stale builds in favor of the latest tree, not a build-up of duplicate work. Upgrade
    // path if this shows up as jank on huge trees: thread FSEvents' per-path info
    // (`kFSEventStreamCreateFlagFileEvents` is already set) out of `DirectoryWatcher`'s
    // callback and route the changed URLs straight to `updateFile`/`removeFile` instead.
    private func rebuildSymbolIndex() {
        indexTask?.cancel()
        let files = ProjectScanner.flatFileList(tree)
        let symbolIndex = symbolIndex
        indexTask = Task.detached(priority: .utility) {
            await symbolIndex.build(files: files)
        }
    }

    /// Hooks into the hosting window: stashes it for sheets and installs the
    /// dirty-tab guard on the red close button (`windowShouldClose`). The guard wraps
    /// SwiftUI's own window delegate so its behaviours keep working.
    func attach(window: NSWindow) {
        self.window = window
        guard closeGuard == nil else { return }
        let closeGuard = ProjectWindowCloseGuard(viewModel: self, wrapping: window.delegate)
        self.closeGuard = closeGuard
        window.delegate = closeGuard
    }

    func open(file: URL) {
        let isNew = !tabs.contains(file)
        if isNew { tabs.append(file) }
        selectedTab = file
        if isNew { notifyLSPDocumentOpened(file) }
    }

    /// Same as `open(file:)`, plus a one-shot reveal of `range` in the newly-shown editor
    /// (Task 9 search-result jumps). `range` is a whole-document UTF-16 `NSRange`. The
    /// target stays set until `CodeEditor` confirms it applied it (`revealConsumed`) —
    /// clearing on confirmed consumption, not a timer, so a reveal into a file whose
    /// editor hasn't rendered yet can never be lost to render-pass timing.
    func open(file: URL, reveal range: NSRange) {
        open(file: file)
        revealTarget = RevealTarget(token: UUID(), range: range)
    }

    // MARK: - Go to Definition (0.7 LSP plan Task 4)

    /// Requests `textDocument/definition` at `offset` (UTF-16, in `url`'s buffer) and
    /// navigates to the result — see `navigateToDefinition`. No-op whenever no server is
    /// alive for `languageID`: same silent-degrade contract every other LSP feature uses
    /// (the menu item is separately disabled via `lspStatusByLanguage`; Cmd+click never
    /// even reaches here in that case — see `CodeEditor.Coordinator.definitionClick`).
    /// `screenAnchor` (screen coordinates) only matters for the multiple-locations picker.
    func goToDefinition(from url: URL, languageID: String?, offset: Int, screenAnchor: NSPoint) {
        guard let languageID, lspStatusByLanguage[languageID] == .running,
              let handle = lspManager.server(for: languageID) else { return }
        Task { [weak self] in
            guard let text = EditorRegistry.shared.fileViewModel(for: url)?.text,
                  let position = LSPPositionBridge.position(of: offset, in: text) else { return }
            let params = TextDocumentPositionParams(uri: url.absoluteString, position: position)
            // Double-optional flatten (mirrors LSPController.requestHover): `definition`
            // throws on transport failure, and its own successful result is itself
            // optional (server found nothing).
            let response = (try? await handle.definition(params: params)) ?? nil
            let locations = GoToDefinition.locations(from: response)
            guard let self, !locations.isEmpty else { return }
            if locations.count == 1 {
                self.navigateToDefinition(locations[0])
            } else {
                GoToDefinition.presentPicker(locations: locations, at: screenAnchor) { [weak self] chosen in
                    self?.navigateToDefinition(chosen)
                }
            }
        }
    }

    /// One resolved `Location` → the actual jump. Same-project file → `open(file:reveal:)`.
    /// Outside `root` → `openOutsideProject`. The target's *current* text (live buffer if
    /// already open somewhere, else read fresh off disk) converts `location.range` to an
    /// `NSRange`; a conversion failure (e.g. the file changed since the server computed the
    /// range) still opens the file, just without a specific reveal, rather than dropping
    /// the whole navigation.
    private func navigateToDefinition(_ location: Location) {
        guard let targetURL = URL(string: location.uri) else { return }
        let rootPath = root.standardizedFileURL.path
        let targetPath = targetURL.standardizedFileURL.path
        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else {
            openOutsideProject(targetURL, range: location.range)
            return
        }
        let text = EditorRegistry.shared.fileViewModel(for: targetURL)?.text
            ?? (try? String(contentsOf: targetURL, encoding: .utf8)) ?? ""
        let range = LSPPositionBridge.nsRange(of: location.range, in: text) ?? NSRange(location: 0, length: 0)
        open(file: targetURL, reveal: range)
    }

    /// Outside this project's root: no standalone single-file window scene exists in this
    /// app (only `WindowGroup("Project", for: URL.self)`), so the lazy-correct stand-in is
    /// the same mechanism Cmd+O already uses to open one file outside any open project —
    /// a *new* project window rooted at the file's parent folder, with the file pre-opened
    /// (and, here, pre-scrolled — see `pendingFileOpenReveal`). `EditorRegistry
    /// .fileViewModel(for:)` returning `nil` is this app's one existing "is this file
    /// openable" check (`FileDocumentModel`'s own read failure), reused rather than
    /// duplicated. Unreadable → reveal in Finder instead (`FileTreeView`'s own fallback for
    /// the same situation).
    private func openOutsideProject(_ url: URL, range: LSPRange) {
        guard let vm = EditorRegistry.shared.fileViewModel(for: url) else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        AppModel.shared.pendingFileOpen = url
        AppModel.shared.pendingFileOpenReveal = LSPPositionBridge.nsRange(of: range, in: vm.text)
        AppModel.shared.openWindowAction?(value: url.deletingLastPathComponent())
    }

    // MARK: - Find References (0.7 LSP plan Task 5)

    /// Requests `textDocument/references` (`includeDeclaration: true`, per the plan) at
    /// `offset` and shows the sidebar's References panel — same silent-no-server-degrade
    /// contract as `goToDefinition`. Empty results beep rather than switch the sidebar to an
    /// empty panel (plan: "subtle feedback... no modal") — whatever the sidebar was already
    /// showing stays put.
    func findReferences(from url: URL, languageID: String?, offset: Int) {
        guard let languageID, lspStatusByLanguage[languageID] == .running,
              let handle = lspManager.server(for: languageID) else { return }
        Task { [weak self] in
            guard let text = EditorRegistry.shared.fileViewModel(for: url)?.text,
                  let position = LSPPositionBridge.position(of: offset, in: text) else { return }
            let params = ReferenceParams(textDocument: TextDocumentIdentifier(uri: url.absoluteString), position: position, includeDeclaration: true)
            // Double-optional flatten (mirrors goToDefinition/requestHover): `references`
            // throws on transport failure, and its own successful result is itself optional.
            let locations = (try? await handle.references(params: params)) ?? nil ?? []
            guard let self else { return }
            let groups = FindReferences.groupedMatches(from: locations)
            guard !groups.isEmpty else {
                NSSound.beep()
                return
            }
            self.referencesResults = groups
            self.sidebarMode = .references
        }
    }

    // MARK: - Document Symbols (0.7 LSP plan Task 5)

    /// Requests `textDocument/documentSymbol` for `url` and shows the quick-open-style
    /// symbols panel — same silent-no-server-degrade contract as `goToDefinition`. Unlike
    /// `findReferences`, an empty result still opens the panel (a plain "No symbols" state —
    /// `QuickOpenView`'s own "No files" precedent) rather than beeping: showing the (empty)
    /// panel already is the feedback that the request ran.
    func showDocumentSymbols(for url: URL, languageID: String?) {
        guard let languageID, lspStatusByLanguage[languageID] == .running,
              let handle = lspManager.server(for: languageID) else { return }
        Task { [weak self] in
            let params = DocumentSymbolParams(textDocument: TextDocumentIdentifier(uri: url.absoluteString))
            let response = (try? await handle.documentSymbol(params: params)) ?? nil
            guard let self else { return }
            self.documentSymbolResults = DocumentSymbols.flatten(response)
            self.documentSymbolsVisible = true
        }
    }

    // MARK: - Rename Symbol (0.7 LSP plan Task 6)

    /// One in-flight rename prompt, shown via `.sheet(item:)` in `ProjectWindow`. Unlike
    /// the Filter Through Command sheet (routed through the app-wide `CommandExecutor
    /// .filterContext` because Commands are shared across every window type — notes
    /// included), rename only ever fires from a project window with a live LSP server
    /// (`5. Notes/no-server: menu disabled` in the plan), so it's scoped straight to this
    /// VM — no cross-window host-matching needed.
    @Published var renameRequest: RenameSymbolRequest?
    /// Transient status-bar text ("Renamed in N files") — the "silent on full success"
    /// half of the plan's results contract; a skipped/failed file instead gets the noisy
    /// half, `presentRenameSummary`'s modal alert. Self-clearing, not a queue: a second
    /// flash before the first clears just restarts the same window on the new text.
    @Published private(set) var statusFlash: String?
    private var statusFlashTask: Task<Void, Never>?

    private func flashStatus(_ message: String) {
        statusFlashTask?.cancel()
        statusFlash = message
        statusFlashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.statusFlash = nil
        }
    }

    /// `textDocument/prepareRename` (best-effort) then shows the rename prompt. Same
    /// silent-no-server-degrade contract as `goToDefinition`/`findReferences`.
    ///
    /// `prepareRename` is optional in the LSP spec — plenty of servers don't implement it.
    /// A failed round trip (transport failure, or a "method not found" JSON-RPC error)
    /// falls back to the local word-under-caret range, exactly as if the server had never
    /// been asked. A *successful* response of `nil`, though, is the server explicitly
    /// saying "nothing renameable here" — treated like `findReferences`' empty-result case
    /// (a beep, not a fallback guess): guessing would mean renaming whatever word sits
    /// under the caret even though the server looked and found nothing.
    func requestRenameSymbol(from url: URL, languageID: String?, offset: Int) {
        guard let languageID, lspStatusByLanguage[languageID] == .running,
              let handle = lspManager.server(for: languageID) else { return }
        Task { [weak self] in
            guard let text = EditorRegistry.shared.fileViewModel(for: url)?.text,
                  let position = LSPPositionBridge.position(of: offset, in: text) else { return }
            let params = PrepareRenameParams(textDocument: TextDocumentIdentifier(uri: url.absoluteString), position: position)
            guard let self else { return }

            // do/catch, not `try?`: Swift flattens `try?` on an `async throws -> T??`
            // call down to one Optional, which would erase exactly the distinction this
            // needs (thrown == unsupported vs. succeeded-with-nil == "nothing here" —
            // see doc comment above). A thrown error (transport failure, or a JSON-RPC
            // "method not found" from a server that never implemented `prepareRename`)
            // falls back to the local word range; a clean `nil` response beeps instead.
            let target: (range: NSRange, name: String)?
            do {
                guard let response = try await handle.prepareRename(params: params) else {
                    NSSound.beep()
                    return
                }
                target = RenameSymbol.target(from: response, position: position, text: text)
            } catch {
                target = RenameSymbol.wordRange(in: text as NSString, at: offset)
                    .map { ($0, (text as NSString).substring(with: $0)) }
            }
            guard let target, !target.name.isEmpty else {
                NSSound.beep()
                return
            }
            self.renameRequest = RenameSymbolRequest(
                fileURL: url, languageID: languageID, offset: offset, position: position, defaultName: target.name
            )
        }
    }

    /// `textDocument/rename` + apply. Re-checks the server's still alive (defensive — the
    /// sheet only ever shows after `requestRenameSymbol`'s own guard already passed, but a
    /// slow prompt racing a server crash is possible) rather than assuming the caller did.
    func performRename(_ request: RenameSymbolRequest, newName: String) {
        guard let handle = lspManager.server(for: request.languageID) else { return }
        Task { [weak self] in
            let params = RenameParams(
                textDocument: TextDocumentIdentifier(uri: request.fileURL.absoluteString),
                position: request.position, newName: newName
            )
            // Double-optional flatten: transport failure, or the server declining to
            // produce an edit for this rename — both are "nothing to apply".
            guard let edit = (try? await handle.rename(params: params)) ?? nil else {
                NSSound.beep()
                return
            }
            guard let self else { return }
            let outcome = RenameSymbol.apply(edit, originatingFile: request.fileURL, originatingOffset: request.offset)
            if let caret = outcome.originatingCaret {
                self.open(file: request.fileURL, reveal: NSRange(location: caret, length: 0))
            }
            self.presentRenameSummary(outcome.results)
        }
    }

    /// Silent on full success (a status-bar flash instead of a modal — plan: "silent on
    /// full success... lazy correct"); a skipped/failed file surfaces the full per-file
    /// list in a modal, since that's the one case that needs the user's attention (a
    /// rename that's only partially applied across the project).
    private func presentRenameSummary(_ results: [RenameSymbol.FileResult]) {
        guard !results.isEmpty else {
            NSSound.beep() // WorkspaceEdit normalized to zero touchable files — nothing happened.
            return
        }
        let failed = results.filter { !$0.success }
        guard !failed.isEmpty else {
            let n = results.count
            flashStatus(n == 1 ? String(localized: "Renamed in 1 file") : String(localized: "Renamed in \(n) files"))
            return
        }
        let succeeded = results.count - failed.count
        let alert = NSAlert()
        alert.messageText = String(localized: "Rename Symbol")
        var lines: [String] = []
        if succeeded > 0 {
            lines.append(succeeded == 1
                ? String(localized: "Renamed successfully in 1 file.")
                : String(localized: "Renamed successfully in \(succeeded) files."))
        }
        lines.append(String(localized: "Not renamed:"))
        lines += failed.map { "\($0.url.lastPathComponent) — \($0.reason ?? String(localized: "unknown error"))" }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: String(localized: "OK"))
        if let window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
    }

    /// Called by the editor after it actually scrolled/selected the target. Token-guarded
    /// so a slow consumer can't clear a newer target: a fresh `CodeEditor.Coordinator` on
    /// a later tab reselect never replays old reveals because the target is gone by then.
    func revealConsumed(_ token: UUID) {
        if revealTarget?.token == token { revealTarget = nil }
    }

    /// Drops the tab unconditionally (no prompt); callers that need the dirty guard use
    /// `requestClose`. Also clears any banner/suppression bookkeeping for the URL.
    func closeTab(_ url: URL) {
        if let languageID = lspLanguageID(for: url) {
            lspManager.documentClosed(url: url, languageID: languageID)
        }
        tabs.removeAll { $0 == url }
        if selectedTab == url { selectedTab = tabs.last }
        banners[url] = nil
        dismissedChanges.remove(url)
        diagnosticsByURI[url.absoluteString] = nil
    }

    var hasTabs: Bool { !tabs.isEmpty }

    #if DEBUG
    private var tabFlipTimer: Timer?
    /// Debug-only regression harness for the tab-switch constraint-feedback crash.
    /// Gated by MEATPAD_TAB_FLIP_TEST=<cycles> (default 400) and
    /// MEATPAD_TAB_FLIP_INTERVAL=<seconds> (default 0.08). When ≥2 tabs are open it
    /// cycles `selectedTab` for N flips, then quits — surfacing the tab-switch
    /// constraint-feedback crash without any UI automation.
    func startTabFlipHarnessIfEnabled() {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["MEATPAD_TAB_FLIP_TEST"], tabFlipTimer == nil else { return }
        guard tabs.count >= 2 else {
            NSLog("[TABFLIP] skipped: only \(tabs.count) tab(s)")
            return
        }
        let cycles = Int(raw) ?? 400
        let interval = env["MEATPAD_TAB_FLIP_INTERVAL"].flatMap(Double.init) ?? 0.08
        var remaining = cycles
        var index = 0
        NSLog("[TABFLIP] starting: \(cycles) flips @ \(interval)s over \(tabs.count) tabs")
        tabFlipTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, !self.tabs.isEmpty else { timer.invalidate(); return }
                index = (index + 1) % self.tabs.count
                self.selectedTab = self.tabs[index]
                remaining -= 1
                if remaining % 50 == 0 { NSLog("[TABFLIP] \(remaining) flips left") }
                if remaining <= 0 {
                    timer.invalidate()
                    NSLog("[TABFLIP] DONE — no crash after \(cycles) flips")
                    NSApp.terminate(nil)
                }
            }
        }
    }
    #endif

    // MARK: - Save / close flows (files only)

    func saveSelectedTab() {
        guard let url = selectedTab, let vm = EditorRegistry.shared.fileViewModel(for: url) else { return }
        do {
            try vm.save()
            // Buffer now matches disk — drop any pending banner/suppression for it.
            banners[url] = nil
            dismissedChanges.remove(url)
        } catch {
            presentError(error, verb: String(localized: "save"), url: url)
        }
    }

    func requestCloseSelectedTab() {
        if let url = selectedTab { requestClose(url) }
    }

    /// Close with the dirty guard: clean → drop immediately; dirty → Save/Discard/Cancel
    /// sheet on this window.
    func requestClose(_ url: URL) {
        guard let vm = EditorRegistry.shared.fileViewModel(for: url), vm.isDirty else {
            closeTab(url)
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Save changes to “\(url.lastPathComponent)” before closing?")
        alert.informativeText = String(localized: "Your changes will be lost if you don't save them.")
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Discard"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        // `vm` is captured strongly only for the sheet's lifetime; released with the
        // completion handler. `self` weak so a dismissed sheet can't pin the window's VM.
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                do { try vm.save(); self?.closeTab(url) }
                catch { self?.presentError(error, verb: String(localized: "save"), url: url) }
            case .alertSecondButtonReturn:
                self?.closeTab(url)
            default:
                break // Cancel
            }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    // MARK: - External change (window became key)

    /// Compares each open buffer against disk. Clean+changed silently takes the disk
    /// version; dirty+changed and deleted raise a banner instead of destroying edits.
    func scanExternalChanges() {
        for url in tabs {
            guard let vm = EditorRegistry.shared.fileViewModel(for: url) else { continue }
            switch vm.checkExternalChange() {
            case .none:
                break
            case .changedOnDisk:
                if vm.isDirty {
                    if !dismissedChanges.contains(url) { banners[url] = .changedOnDisk }
                } else {
                    try? vm.revert()
                    banners[url] = nil
                }
            case .deleted:
                if !dismissedChanges.contains(url) { banners[url] = .deleted }
            }
        }
    }

    /// Red-button close guard: true = let the window close. Dirty tabs raise one summary
    /// alert (modal — `windowShouldClose` needs a synchronous answer).
    func confirmWindowClose() -> Bool {
        let dirty = tabs.compactMap { EditorRegistry.shared.fileViewModel(for: $0) }.filter(\.isDirty)
        guard !dirty.isEmpty else { return true }

        let alert = NSAlert()
        alert.messageText = dirty.count == 1
            ? String(localized: "1 document has unsaved changes.")
            : String(localized: "\(dirty.count) documents have unsaved changes.")
        alert.informativeText = String(localized: "Do you want to save your changes before closing?")
        alert.addButton(withTitle: String(localized: "Save All & Close"))
        alert.addButton(withTitle: String(localized: "Discard & Close"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return FileEditorViewModel.saveAllReportingFailures(dirty)
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func reload(_ url: URL) {
        if let vm = EditorRegistry.shared.fileViewModel(for: url) { try? vm.revert() }
        banners[url] = nil
        dismissedChanges.remove(url)
        notifyLSPDocumentChanged(url)
    }

    /// "Keep Mine" / "Dismiss": hide the banner and stop re-raising it on every
    /// window-key until the doc is next saved/reverted/reopened.
    func dismissBanner(_ url: URL) {
        banners[url] = nil
        dismissedChanges.insert(url)
    }

    /// Dismisses the missing-server notice. `lspBannerShownLanguages` already stops it
    /// from coming back this session — nothing else to record here.
    func dismissLSPBanner() {
        lspBanner = nil
    }

    // MARK: - LSP document lifecycle

    /// `url`'s language ID, but only when it's one `LSPProjectManager` knows how to
    /// launch a server for — the gate that keeps every other language from ever
    /// touching `lspManager`.
    private func lspLanguageID(for url: URL) -> String? {
        guard let languageID = EditorRegistry.shared.fileViewModel(for: url)?.language?.id,
              Self.lspKnownLanguageIDs.contains(languageID) else { return nil }
        return languageID
    }

    /// Sends `textDocument/didOpen` (lazily starting that language's server on first
    /// use) and, the first time this project sees that language come up missing,
    /// raises the install-hint banner.
    private func notifyLSPDocumentOpened(_ url: URL) {
        guard let vm = EditorRegistry.shared.fileViewModel(for: url),
              let languageID = vm.language?.id, Self.lspKnownLanguageIDs.contains(languageID) else { return }
        lspManager.documentOpened(url: url, languageID: languageID, text: vm.text)

        guard !lspBannerShownLanguages.contains(languageID),
              case .notInstalled(let installHint) = lspManager.statusByLanguage[languageID] else { return }
        lspBannerShownLanguages.insert(languageID)
        lspBanner = LSPBannerState(
            languageID: languageID,
            languageName: Languages.byID(languageID)?.name ?? languageID,
            installHint: installHint
        )
    }

    /// Debounced `textDocument/didChange` — called from `CodeEditor`'s existing
    /// highlight debounce (see `CodeEditor.onDocumentChanged`) rather than on every
    /// keystroke.
    func notifyLSPDocumentChanged(_ url: URL) {
        guard let languageID = lspLanguageID(for: url) else { return }
        let text = EditorRegistry.shared.fileViewModel(for: url)?.text ?? ""
        lspManager.documentChanged(url: url, languageID: languageID, text: text)
    }

    private func presentError(_ error: Error, verb: String, url: URL) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Couldn't \(verb) “\(url.lastPathComponent)”.")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: String(localized: "OK"))
        if let window { alert.beginSheetModal(for: window, completionHandler: nil) }
        else { alert.runModal() }
    }
}

/// `NSWindowDelegate` proxy installed on a project window: intercepts `windowShouldClose`
/// for the dirty-tab guard and forwards every other delegate call to SwiftUI's original
/// delegate via `forwardingTarget`, so window restoration/tabbing behaviours survive.
final class ProjectWindowCloseGuard: NSObject, NSWindowDelegate {
    private weak var viewModel: ProjectViewModel?
    /// SwiftUI keeps its own strong reference to its delegate; weak here avoids a cycle.
    private weak var original: NSWindowDelegate?

    init(viewModel: ProjectViewModel, wrapping original: NSWindowDelegate?) {
        self.viewModel = viewModel
        self.original = original
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || original?.responds(to: aSelector) == true
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if original?.responds(to: aSelector) == true { return original }
        return super.forwardingTarget(for: aSelector)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Delegate callbacks arrive on the main thread; hop onto the actor explicitly
        // (same pattern as the STTextViewDelegate callbacks).
        let allowed = MainActor.assumeIsolated { viewModel?.confirmWindowClose() ?? true }
        guard allowed else { return false }
        let willClose: Bool
        if let original, original.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))) {
            willClose = original.windowShouldClose?(sender) ?? true
        } else {
            willClose = true
        }
        // Only tear down the project's language servers once the window is actually
        // closing — `original`'s answer (if any) is the final word, so this can't fire
        // on a close that gets vetoed after our own guard already said yes.
        if willClose {
            MainActor.assumeIsolated { viewModel?.lspManager.shutdown() }
        }
        return willClose
    }
}
