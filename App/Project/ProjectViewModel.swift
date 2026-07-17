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

    let root: URL
    @Published var tree: TreeNode
    @Published var tabs: [URL] = []
    @Published var selectedTab: URL?
    /// At-most-one-visible per tab; the host shows `banners[selectedTab]`.
    @Published var banners: [URL: Banner] = [:]

    /// Set via `WindowAccessor` so the dirty-close/save sheets attach to this window.
    weak var window: NSWindow?

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

    func open(file: URL) {
        if !tabs.contains(file) { tabs.append(file) }
        selectedTab = file
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
                banners[url] = .deleted
            }
        }
    }

    func reload(_ url: URL) {
        if let vm = EditorRegistry.shared.fileViewModel(for: url) { try? vm.revert() }
        banners[url] = nil
        dismissedChanges.remove(url)
    }

    func keepMine(_ url: URL) {
        banners[url] = nil
        dismissedChanges.insert(url)
    }

    func dismissBanner(_ url: URL) {
        banners[url] = nil
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
