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
    // NSStringFromRect(window.frame); nil = never positioned (legacy sidecars decode
    // fine — synthesized Codable treats a missing key on an optional as nil).
    public var windowFrame: String?
    // User folder name; nil = the implicit default "Notes" folder. Same legacy-decode
    // story as windowFrame.
    public var folder: String?

    public init(id: UUID, languageID: String?, created: Date, modified: Date, cursor: Int, title: String, windowFrame: String? = nil, folder: String? = nil) {
        self.id = id
        self.languageID = languageID
        self.created = created
        self.modified = modified
        self.cursor = cursor
        self.title = title
        self.windowFrame = windowFrame
        self.folder = folder
    }
}

extension Note {
    /// Derives the display title from note contents: the first non-empty line, trimmed;
    /// "New Note" if the contents have no non-empty line. Public so the app can recompute
    /// a live window title on every keystroke, without waiting for the debounced autosave.
    public static func title(fromContents contents: String) -> String {
        // `split(separator: "\n")` alone misses CRLF content: "\r\n" is a single
        // extended grapheme cluster in Swift, not a "\n" Character, so it never
        // matches that separator. `\.isNewline` matches \n, \r, and \r\n alike.
        for line in contents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return "New Note"
    }
}
