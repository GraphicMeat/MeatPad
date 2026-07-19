import Foundation

/// One entry in a scanned project tree. `children == nil` means "not a directory";
/// directories always have a (possibly empty) array. `scan` fills it in eagerly and
/// recursively; `scanShallow` only fills the top level and leaves subdirectories at
/// `[]` as a disclosure-triangle placeholder until a full `scan` swaps in.
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

    /// Scans `root` recursively. Directories sort before files; both alphabetical,
    /// case-insensitive. Symlinks are never followed — treated as plain files, which
    /// also sidesteps symlink cycles.
    public static func scan(root: URL, showHidden: Bool = false) -> TreeNode {
        TreeNode(
            url: root,
            name: root.lastPathComponent,
            isDirectory: true,
            children: children(of: root, showHidden: showHidden, recursive: true)
        )
    }

    /// Lists only `root`'s immediate entries — subdirectories get `children: []` rather
    /// than being walked. Lets callers render a window instantly, then swap in a full
    /// `scan` once it's ready. Goes through the same `children(of:)` sort path as `scan`
    /// so rows don't reorder when that swap happens.
    public static func scanShallow(root: URL, showHidden: Bool = false) -> TreeNode {
        TreeNode(
            url: root,
            name: root.lastPathComponent,
            isDirectory: true,
            children: children(of: root, showHidden: showHidden, recursive: false)
        )
    }

    /// Files only, recursive, in the same order they appear in the tree — for quick-open.
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

    private static func children(of directory: URL, showHidden: Bool, recursive: Bool) -> [TreeNode] {
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

            let isSymlink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
            let isDir = isSymlink ? false : ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false)

            if isDir {
                let subChildren = recursive ? children(of: url, showHidden: showHidden, recursive: true) : []
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
