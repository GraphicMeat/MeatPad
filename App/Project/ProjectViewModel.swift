import Foundation
import MeatPadKit

/// Owns one project window's state: the live file tree (rescanned on any change under
/// `root`) and the list of files opened as tabs. Task 7 fills in the tab host UI; this
/// just tracks which URLs are open and which is selected.
@MainActor
final class ProjectViewModel: ObservableObject {
    let root: URL
    @Published var tree: TreeNode
    @Published var tabs: [URL] = []
    @Published var selectedTab: URL?

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
    }

    func open(file: URL) {
        if !tabs.contains(file) { tabs.append(file) }
        selectedTab = file
    }

    /// Dirty-prompt (if any) is the caller's job — this just drops the tab.
    func closeTab(_ url: URL) {
        tabs.removeAll { $0 == url }
        if selectedTab == url { selectedTab = tabs.last }
    }
}
