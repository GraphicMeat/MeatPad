import Foundation

/// Metadata for a single unsaved-buffer "note". Contents live in a sibling `.txt` file;
/// this struct is the JSON sidecar.
public struct Note: Identifiable, Equatable, Sendable, Codable {
    public var id: UUID
    public var languageID: String?      // manual override; nil = auto-detect
    public var created: Date
    public var modified: Date
    public var cursor: Int              // UTF-16 offset
    public var title: String            // derived: first non-empty line, else "New Note"

    public init(id: UUID, languageID: String?, created: Date, modified: Date, cursor: Int, title: String) {
        self.id = id
        self.languageID = languageID
        self.created = created
        self.modified = modified
        self.cursor = cursor
        self.title = title
    }
}

extension Note {
    /// Derives the display title from note contents: the first non-empty line, trimmed;
    /// "New Note" if the contents have no non-empty line. Public so the app can recompute
    /// a live window title on every keystroke, without waiting for the debounced autosave.
    public static func title(fromContents contents: String) -> String {
        for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return "New Note"
    }
}
