import Foundation

/// One entry in a scanned project tree. `children == nil` means "not a directory";
/// directories always have a (possibly empty) array. `scan` only fills in the folders it is
/// told are expanded; every other directory keeps `[]` as a disclosure-triangle placeholder
/// until the user unfolds it, so memory follows what is on screen, not the project's size.
public struct TreeNode: Identifiable, Equatable, Sendable {
    public let url: URL
    public var id: URL { url }
    public let name: String
    public let isDirectory: Bool
    public var children: [TreeNode]?
}

public enum ProjectScanner {
    /// Exact set referenced by later tasks (sidebar, quick-open) — don't change without
    /// checking callers.
    public static let ignoredNames: Set<String> = [".git", "node_modules", ".build", "DerivedData", ".DS_Store"]

    /// Extra generated/vendored folders `forEachFile` (search, quick-open, the symbol index) skips on top
    /// of `ignoredNames`. The sidebar still shows them: it only reads a folder when unfolded.
    public static let walkIgnoredNames: Set<String> = ignoredNames.union(["Pods", "__pycache__", "venv", "target", "dist", "build"])

    /// Lists `root`, descending only into directories listed in `expanded` (`nil` = every
    /// directory, the old full scan). Directories sort before files; both alphabetical,
    /// case-insensitive. Symlinks are never followed — treated as plain files, which
    /// also sidesteps symlink cycles. `root` itself is always listed.
    public static func scan(root: URL, showHidden: Bool = false, expanded: Set<URL>? = nil) -> TreeNode {
        TreeNode(
            url: root,
            name: root.lastPathComponent,
            isDirectory: true,
            children: children(of: root, showHidden: showHidden, expanded: expanded)
        )
    }

    /// Lists only `root`'s immediate entries — subdirectories get `children: []` rather
    /// than being walked.
    public static func scanShallow(root: URL, showHidden: Bool = false) -> TreeNode {
        scan(root: root, showHidden: showHidden, expanded: [])
    }

    /// Every regular file under `root` (depth first), without building a tree: memory stays flat
    /// however big the project is. Same hidden-file and symlink rules as `scan`, minus the
    /// `walkIgnoredNames`. `body` returns `false` to stop the walk early.
    public static func forEachFile(root: URL, showHidden: Bool = false, _ body: (URL) -> Bool) {
        var pending = [root]
        while let directory = pending.popLast() {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]
            )) ?? []
            for url in entries {
                let name = url.lastPathComponent
                if walkIgnoredNames.contains(name) { continue }
                if !showHidden && name.hasPrefix(".") { continue }
                if isDirectory(url) {
                    pending.append(url)
                } else if !body(url) {
                    return
                }
            }
        }
    }

    /// Files only, recursive, in the same order they appear in the tree — for the symbol index
    /// (tree files = the unfolded ones).
    public static func flatFileList(_ root: TreeNode) -> [URL] {
        guard let children = root.children else { return [] }
        var result: [URL] = []
        for child in children {
            if child.isDirectory {
                result.append(contentsOf: flatFileList(child))
            } else {
                result.append(child.url)
            }
        }
        return result
    }

    private static func isDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]) else { return false }
        return values.isSymbolicLink != true && values.isDirectory == true
    }

    private static func children(of directory: URL, showHidden: Bool, expanded: Set<URL>?) -> [TreeNode] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]
        )) ?? []

        var dirs: [TreeNode] = []
        var files: [TreeNode] = []

        for url in entries {
            let name = url.lastPathComponent
            if ignoredNames.contains(name) { continue }
            if !showHidden && name.hasPrefix(".") { continue }

            if isDirectory(url) {
                let isOpen = expanded?.contains(url) ?? true
                let subChildren = isOpen ? children(of: url, showHidden: showHidden, expanded: expanded) : []
                dirs.append(TreeNode(url: url, name: name, isDirectory: true, children: subChildren))
            } else {
                files.append(TreeNode(url: url, name: name, isDirectory: false, children: nil))
            }
        }

        dirs.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        files.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return dirs + files
    }
}
