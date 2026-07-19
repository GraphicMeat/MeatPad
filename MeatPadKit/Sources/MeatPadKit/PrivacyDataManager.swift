import Foundation

/// Pure filesystem logic behind Settings ▸ Privacy's Relocate/Export/Delete-All flows
/// (0.8 Task 5). Kept here (not app-side) because it's plain `FileManager` work with no
/// AppKit dependency, so it's headlessly testable — the app layer only adds the
/// `NSOpenPanel`/alert UI and the final `NSWorkspace.recycle` call (AppKit-only, stays
/// app-side).
public enum PrivacyDataManager {
    /// The top-level entries a MeatPad storage root may contain: the five sibling
    /// directories plus `session.json`. Copy/verify/recycle only ever touch entries from
    /// this list that actually exist — a fresh install with no saved Macros, say, just
    /// skips that one, and anything else a user dropped into the folder is left alone.
    public static let managedArtifactNames = ["Notes", "Snippets", "Commands", "Macros", "Themes", "session.json"]

    /// Recursive file (not directory) count at `url`. A single file counts as 1; a
    /// missing path counts as 0 (a sibling that doesn't exist yet isn't a copy failure).
    public static func fileCount(at url: URL, fileManager: FileManager = .default) -> Int {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else { return 1 }
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
        var count = 0
        for case let fileURL as URL in enumerator {
            if (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                count += 1
            }
        }
        return count
    }

    /// The managed artifact URLs under `base` that actually exist, in `artifactNames`
    /// order — what Export copies and Delete All recycles.
    public static func existingArtifacts(
        at base: URL, artifactNames: [String] = managedArtifactNames, fileManager: FileManager = .default
    ) -> [URL] {
        artifactNames.map { base.appendingPathComponent($0) }.filter { fileManager.fileExists(atPath: $0.path) }
    }

    /// Copies every existing managed artifact from `sourceBase` into `destinationBase`
    /// (created if needed) and verifies each copy landed intact — recursive file count at
    /// the destination must equal the source. Returns the per-artifact file counts on
    /// success. Throws `PrivacyDataError.verificationFailed` on any mismatch, WITHOUT
    /// deleting anything already copied; callers (Relocate/Export) treat that as an abort —
    /// Relocate in particular must never flip the storage-root override on an unverified
    /// copy.
    @discardableResult
    public static func copyManagedArtifacts(
        from sourceBase: URL, to destinationBase: URL,
        artifactNames: [String] = managedArtifactNames, fileManager: FileManager = .default
    ) throws -> [String: Int] {
        // Guard BEFORE any mutation: if destination is the source root itself, the
        // per-artifact overwrite branch below would `removeItem(at: destination)` on a
        // path that IS the source (hard delete, no Trash), then `copyItem` throws because
        // there's nothing left to copy. Same hazard, gentler trigger, if destination is
        // merely nested inside the source tree. Standardized path-prefix check (with the
        // trailing separator) so "/x/MeatPadBackup" isn't mistaken for a descendant of
        // "/x/MeatPad".
        let sourcePath = sourceBase.standardizedFileURL.path
        let destinationPath = destinationBase.standardizedFileURL.path
        if destinationPath == sourcePath || destinationPath.hasPrefix(sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/") {
            throw PrivacyDataError.destinationInsideSource(source: sourcePath, destination: destinationPath)
        }
        try fileManager.createDirectory(at: destinationBase, withIntermediateDirectories: true)
        var counts: [String: Int] = [:]
        for name in artifactNames {
            let source = sourceBase.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = destinationBase.appendingPathComponent(name)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: source, to: destination)
            let sourceCount = fileCount(at: source, fileManager: fileManager)
            let destinationCount = fileCount(at: destination, fileManager: fileManager)
            guard sourceCount == destinationCount else {
                throw PrivacyDataError.verificationFailed(artifact: name, sourceCount: sourceCount, destinationCount: destinationCount)
            }
            counts[name] = destinationCount
        }
        return counts
    }
}

public enum PrivacyDataError: Error, LocalizedError, Equatable {
    case verificationFailed(artifact: String, sourceCount: Int, destinationCount: Int)
    /// Destination equals, or is nested inside, the source storage root — copying there
    /// would delete or corrupt the very data being copied. See `copyManagedArtifacts`.
    case destinationInsideSource(source: String, destination: String)

    public var errorDescription: String? {
        switch self {
        case .verificationFailed(let artifact, let sourceCount, let destinationCount):
            return "Copy verification failed for \(artifact): \(sourceCount) file(s) at source, \(destinationCount) at destination."
        case .destinationInsideSource:
            return "Choose a folder outside the current storage location."
        }
    }
}
