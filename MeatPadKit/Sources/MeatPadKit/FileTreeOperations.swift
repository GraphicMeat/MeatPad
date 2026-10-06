import Foundation

public enum FileTreeError: Error, Equatable, Sendable {
    case invalidName
    case alreadyExists(String)
    case cannotMoveIntoItself
}

public enum FileTreePaths {
    /// `url` relative to `root` ("src/main.swift", "." for the root itself). Outside the root
    /// there is nothing sensible to be relative to, so the absolute path comes back.
    public static func relativePath(of url: URL, in root: URL) -> String {
        let target = components(url)
        let base = components(root)
        guard target.count >= base.count, Array(target.prefix(base.count)) == base else { return url.path }
        let rest = target.dropFirst(base.count)
        return rest.isEmpty ? "." : rest.joined(separator: "/")
    }

    /// Where "New File" / "Paste" / "Open in Terminal" act: the folder itself, or a file's parent.
    public static func containingDirectory(of url: URL, isDirectory: Bool) -> URL {
        isDirectory ? url : url.deletingLastPathComponent()
    }

    fileprivate static func components(_ url: URL) -> [String] {
        url.standardizedFileURL.path.split(separator: "/").map(String.init)
    }
}

/// The file-system half of the sidebar menu. Every call throws rather than half-doing a job,
/// and nothing here overwrites: a name that is taken is an error (create/rename) or gets a
/// "copy" suffix (paste).
public enum FileTreeOperations {

    @discardableResult
    public static func createFile(named name: String, in directory: URL) throws -> URL {
        let url = try destination(named: name, in: directory)
        try Data().write(to: url, options: .withoutOverwriting)
        return url
    }

    @discardableResult
    public static func createFolder(named name: String, in directory: URL) throws -> URL {
        let url = try destination(named: name, in: directory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// Renames in place. The same name is a no-op; a case-only change is allowed on a
    /// case-insensitive volume, where the "taken" name is the item itself.
    @discardableResult
    public static func rename(_ url: URL, to name: String) throws -> URL {
        let trimmed = try validated(name)
        if trimmed == url.lastPathComponent { return url }
        let target = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        let caseOnly = trimmed.lowercased() == url.lastPathComponent.lowercased()
        if !caseOnly && exists(target) { throw FileTreeError.alreadyExists(trimmed) }
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    /// Moves to the Trash — recoverable, never a hard delete.
    public static func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Copies (or, for a cut, moves) `sources` into `directory` and returns the new locations.
    /// A name already there becomes "name copy.ext", "name copy 2.ext", …; a move into the
    /// folder the item already lives in changes nothing.
    @discardableResult
    public static func paste(_ sources: [URL], into directory: URL, move: Bool) throws -> [URL] {
        let fm = FileManager.default
        let directoryComponents = FileTreePaths.components(directory)
        var results: [URL] = []
        for source in sources {
            let sourceComponents = FileTreePaths.components(source)
            if isDirectory(source),
               directoryComponents.count >= sourceComponents.count,
               Array(directoryComponents.prefix(sourceComponents.count)) == sourceComponents {
                throw FileTreeError.cannotMoveIntoItself
            }
            if move && FileTreePaths.components(source.deletingLastPathComponent()) == directoryComponents {
                results.append(source)
                continue
            }
            let target = uniqueDestination(for: source, in: directory)
            if move { try fm.moveItem(at: source, to: target) } else { try fm.copyItem(at: source, to: target) }
            results.append(target)
        }
        return results
    }

    // MARK: - helpers

    private static func validated(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !trimmed.contains("/") else {
            throw FileTreeError.invalidName
        }
        return trimmed
    }

    private static func destination(named name: String, in directory: URL) throws -> URL {
        let trimmed = try validated(name)
        let url = directory.appendingPathComponent(trimmed)
        if exists(url) { throw FileTreeError.alreadyExists(trimmed) }
        return url
    }

    /// `fileExists` follows symlinks, so a dangling link would read as free; ask the link itself.
    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    private static func uniqueDestination(for source: URL, in directory: URL) -> URL {
        let name = source.lastPathComponent
        let first = directory.appendingPathComponent(name)
        guard exists(first) else { return first }
        // Folders keep dots in their names ("assets.v2"); only files have an extension to protect.
        let ext = isDirectory(source) ? "" : source.pathExtension
        let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        let suffix = ext.isEmpty ? "" : "." + ext
        var n = 1
        while true {
            let candidate = directory.appendingPathComponent("\(base) copy\(n == 1 ? "" : " \(n)")\(suffix)")
            if !exists(candidate) { return candidate }
            n += 1
        }
    }
}
