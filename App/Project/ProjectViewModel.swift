import Foundation
import AppKit
import MeatPadKit

/// Owns one project window's state: the live file tree (rescanned on any change under
/// `root`), the open tabs, and the save/close/external-change flows over them. The file
/// buffers themselves live in `EditorRegistry` (canonical per-URL VMs); this coordinates
/// which are open and drives the dialogs that only apply to files (notes stay silent).
@MainActor
final class ProjectViewModel: ObservableObject {
    /// Banner shown over the editor when disk diverges from the open buffer.
    enum Banner: Equatable { case changedOnDisk, deleted }

    /// Which content the sidebar shows: the live file tree, or Cmd+Shift+F project search.
    enum SidebarMode: Hashable { case files, search }

    let root: URL
    @Published var tree: TreeNode
    @Published var tabs: [URL] = []
    @Published var selectedTab: URL?
    /// At-most-one-visible per tab; the host shows `banners[selectedTab]`.
    @Published var banners: [URL: Banner] = [:]
    /// Cmd+T quick-open overlay, toggled by the app-level command.
    @Published var quickOpenVisible = false
    @Published var sidebarMode: SidebarMode = .files
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

    init(root: URL) {
        self.root = root
        // Shows the window instantly with just the top level, then `rescan()` below
        // fills in the full tree off the main thread — opening a big repo no longer
        // blocks the window from appearing.
        self.tree = ProjectScanner.scanShallow(root: root)
        self.watcher = DirectoryWatcher(root: root) { [weak self] in
            self?.rescan()
        }
        rescan()
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
        }
    }

    /// Runs a full recursive scan off the main actor and swaps it in when done. Cancels
    /// any scan already in flight first, so the watcher firing repeatedly during a big
    /// FS change (e.g. a git checkout) doesn't queue up redundant work.
    func rescan() {
        scanTask?.cancel()
        let root = root
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let scanned = ProjectScanner.scan(root: root)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.tree = scanned
            }
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
        if !tabs.contains(file) { tabs.append(file) }
        selectedTab = file
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

    /// Called by the editor after it actually scrolled/selected the target. Token-guarded
    /// so a slow consumer can't clear a newer target: a fresh `CodeEditor.Coordinator` on
    /// a later tab reselect never replays old reveals because the target is gone by then.
    func revealConsumed(_ token: UUID) {
        if revealTarget?.token == token { revealTarget = nil }
    }

    /// Drops the tab unconditionally (no prompt); callers that need the dirty guard use
    /// `requestClose`. Also clears any banner/suppression bookkeeping for the URL.
    func closeTab(_ url: URL) {
        tabs.removeAll { $0 == url }
        if selectedTab == url { selectedTab = tabs.last }
        banners[url] = nil
        dismissedChanges.remove(url)
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
    }

    /// "Keep Mine" / "Dismiss": hide the banner and stop re-raising it on every
    /// window-key until the doc is next saved/reverted/reopened.
    func dismissBanner(_ url: URL) {
        banners[url] = nil
        dismissedChanges.insert(url)
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
        if let original, original.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))) {
            return original.windowShouldClose?(sender) ?? true
        }
        return true
    }
}
