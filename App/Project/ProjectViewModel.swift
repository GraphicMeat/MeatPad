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

    init(root: URL) {
        self.root = root
        self.tree = ProjectScanner.scan(root: root)
        self.watcher = DirectoryWatcher(root: root) { [weak self] in
            guard let self else { return }
            self.tree = ProjectScanner.scan(root: self.root)
        }
        // Task 6 leftover: Cmd+O on a file opens its parent as a project and pre-opens the
        // file as a tab. AppModel stashes the file; consume it if it lives under this root.
        if let pending = AppModel.shared.pendingFileOpen,
           pending.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL {
            tabs = [pending]
            selectedTab = pending
            AppModel.shared.pendingFileOpen = nil
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
    /// (Task 9 search-result jumps). `range` is a whole-document UTF-16 `NSRange`.
    func open(file: URL, reveal range: NSRange) {
        open(file: file)
        let target = RevealTarget(token: UUID(), range: range)
        revealTarget = target
        // `CodeEditor.updateNSView` consumes the token synchronously on the render pass
        // this triggers; clearing it right after means a *future* reselect of this same
        // tab (a fresh `CodeEditor.Coordinator`, which has no memory of consumed tokens)
        // won't replay this reveal.
        DispatchQueue.main.async { [weak self] in
            if self?.revealTarget?.token == target.token { self?.revealTarget = nil }
        }
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

    // MARK: - Save / close flows (files only)

    func saveSelectedTab() {
        guard let url = selectedTab, let vm = EditorRegistry.shared.fileViewModel(for: url) else { return }
        do {
            try vm.save()
            // Buffer now matches disk — drop any pending banner/suppression for it.
            banners[url] = nil
            dismissedChanges.remove(url)
        } catch {
            presentError(error, verb: "save", url: url)
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
        alert.messageText = "Save changes to “\(url.lastPathComponent)” before closing?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        // `vm` is captured strongly only for the sheet's lifetime; released with the
        // completion handler. `self` weak so a dismissed sheet can't pin the window's VM.
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                do { try vm.save(); self?.closeTab(url) }
                catch { self?.presentError(error, verb: "save", url: url) }
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
            ? "1 document has unsaved changes."
            : "\(dirty.count) documents have unsaved changes."
        alert.informativeText = "Do you want to save your changes before closing?"
        alert.addButton(withTitle: "Save All & Close")
        alert.addButton(withTitle: "Discard & Close")
        alert.addButton(withTitle: "Cancel")
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
        alert.messageText = "Couldn't \(verb) “\(url.lastPathComponent)”."
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
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
