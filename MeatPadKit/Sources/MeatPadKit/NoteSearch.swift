import Foundation

/// A single search result: either a title match, a content match, or both.
public struct NoteSearchMatch: Equatable, Sendable {
    public let noteID: UUID
    public let isTitleMatch: Bool
    /// Excerpt text around the first content hit (title matches: excerpt of content start; empty content → "").
    public let excerpt: String
    /// Range of the query hit WITHIN excerpt (UTF-16), for bold rendering. nil for title-only matches with no content hit.
    public let rangeInExcerpt: NSRange?
    /// Range of the first hit in the FULL contents (UTF-16) — reveal target. nil if title-only match.
    public let rangeInContents: NSRange?

    public init(noteID: UUID, isTitleMatch: Bool, excerpt: String, rangeInExcerpt: NSRange?, rangeInContents: NSRange?) {
        self.noteID = noteID
        self.isTitleMatch = isTitleMatch
        self.excerpt = excerpt
        self.rangeInExcerpt = rangeInExcerpt
        self.rangeInContents = rangeInContents
    }
}

/// In-memory full-text index of note contents, keyed by note id. The caller (`NoteStore`)
/// keeps this in sync via `update`/`remove` as notes are edited/trashed; it is never
/// persisted — rebuilt from scratch each launch. No SQLite/FTS5 (interview decision):
/// note counts here don't warrant it, and this keeps the feature dependency-free.
@MainActor public final class NoteSearchIndex {
    private var contentsByID: [UUID: String] = [:]

    /// UTF-16 units of context kept before/after a hit when building an excerpt, before
    /// snapping to line boundaries.
    private static let excerptBefore = 40
    private static let excerptAfter = 120

    public init() {}

    public func update(id: UUID, contents: String) {
        contentsByID[id] = contents
    }

    public func remove(id: UUID) {
        contentsByID.removeValue(forKey: id)
    }

    /// notes: metadata in display order (already folder-filtered by caller).
    /// Returns title matches first (preserving input order), then content-only matches.
    public func search(_ query: String, notes: [Note]) -> [NoteSearchMatch] {
        guard !query.isEmpty else {
            return notes.map {
                NoteSearchMatch(noteID: $0.id, isTitleMatch: true, excerpt: "", rangeInExcerpt: nil, rangeInContents: nil)
            }
        }

        var titleMatches: [NoteSearchMatch] = []
        var contentMatches: [NoteSearchMatch] = []
        for note in notes {
            let contents = contentsByID[note.id] ?? ""
            let hit = Self.firstHit(of: query, in: contents)
            let isTitleMatch = note.title.localizedCaseInsensitiveContains(query)

            if isTitleMatch {
                // No content hit: still show an excerpt of the content's start (anchor at
                // location 0, zero-length — the shared window builder treats that as "no
                // bold span" for free).
                let anchor = hit ?? NSRange(location: 0, length: 0)
                let (excerpt, rangeInExcerpt) = Self.excerptWindow(contents: contents, anchor: anchor)
                titleMatches.append(NoteSearchMatch(noteID: note.id, isTitleMatch: true, excerpt: excerpt, rangeInExcerpt: rangeInExcerpt, rangeInContents: hit))
            } else if let hit {
                let (excerpt, rangeInExcerpt) = Self.excerptWindow(contents: contents, anchor: hit)
                contentMatches.append(NoteSearchMatch(noteID: note.id, isTitleMatch: false, excerpt: excerpt, rangeInExcerpt: rangeInExcerpt, rangeInContents: hit))
            }
        }
        return titleMatches + contentMatches
    }

    /// First case-insensitive, locale-aware occurrence of `query` in `contents` — same
    /// matching semantics as `String.localizedCaseInsensitiveContains`, but with a
    /// location so excerpts can be built. nil if `contents` is empty or has no hit.
    private static func firstHit(of query: String, in contents: String) -> NSRange? {
        guard !contents.isEmpty else { return nil }
        let ns = contents as NSString
        let range = ns.range(of: query, options: [.caseInsensitive], range: NSRange(location: 0, length: ns.length), locale: Locale.current)
        return range.location == NSNotFound ? nil : range
    }

    /// Builds an excerpt around `anchor` (a real hit range, or a zero-length range at 0
    /// to mean "start of content, no bold span"): ~40 UTF-16 units before to ~120 after,
    /// snapped outward to the nearest line boundary, newlines collapsed to spaces
    /// (character-for-character, so it never shifts any UTF-16 offset), with "…"
    /// affixed on whichever side got truncated. Returns the excerpt and the anchor's
    /// range within it (nil when the anchor was zero-length, i.e. no bold span).
    private static func excerptWindow(contents: String, anchor: NSRange) -> (excerpt: String, rangeInExcerpt: NSRange?) {
        let ns = contents as NSString
        let length = ns.length
        guard length > 0 else { return ("", nil) }

        var windowStart = max(0, anchor.location - excerptBefore)
        var windowEnd = min(length, anchor.location + anchor.length + excerptAfter)

        if windowStart > 0 {
            let found = ns.rangeOfCharacter(from: .newlines, options: .backwards, range: NSRange(location: 0, length: windowStart))
            windowStart = found.location == NSNotFound ? 0 : found.location + found.length
        }
        if windowEnd < length {
            let found = ns.rangeOfCharacter(from: .newlines, options: [], range: NSRange(location: windowEnd, length: length - windowEnd))
            windowEnd = found.location == NSNotFound ? length : found.location
        }

        let window = NSMutableString(string: ns.substring(with: NSRange(location: windowStart, length: windowEnd - windowStart)))
        for i in 0..<window.length {
            // `Unicode.Scalar(UInt16)` fails for lone surrogate halves (emoji etc.) —
            // those are never newlines, so skip rather than force-unwrap and crash.
            guard let scalar = Unicode.Scalar(window.character(at: i)), CharacterSet.newlines.contains(scalar) else { continue }
            window.replaceCharacters(in: NSRange(location: i, length: 1), with: " ")
        }

        let hasPrefix = windowStart > 0
        let hasSuffix = windowEnd < length
        var excerpt = window as String
        if hasPrefix { excerpt = "…" + excerpt }
        if hasSuffix { excerpt += "…" }

        var rangeInExcerpt: NSRange?
        if anchor.length > 0 {
            rangeInExcerpt = NSRange(location: anchor.location - windowStart + (hasPrefix ? 1 : 0), length: anchor.length)
        }
        return (excerpt, rangeInExcerpt)
    }
}
