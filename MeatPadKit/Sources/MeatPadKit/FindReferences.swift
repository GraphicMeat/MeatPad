import Foundation
import LanguageServerProtocol

/// Find References (0.7 LSP plan Task 5): `textDocument/references` response → grouped-by-
/// file preview rows. Reuses `SearchMatch`/`FileMatchGroup` (`SearchEngine.swift`) rather
/// than inventing a parallel row type, so the App's `ReferencesView` can share
/// `ProjectSearchView`'s DisclosureGroup shape and row-open logic. Split into two pure
/// pieces the App target's `FindReferences.swift` composes: `searchMatch` (line-clamp +
/// UTF-16 `rangeInLine` math, given already-resolved line text) and `group` (first-seen
/// file order). Reading a location's line text is impure (live buffer vs. disk fallback via
/// `EditorRegistry`) and stays in the App target.
public enum FindReferences {
    /// Builds one `Location` → one `SearchMatch` line preview. `lines` is the target file's
    /// text already split on `"\n"`. Returns `nil` if `location`'s start line is out of range
    /// for `lines` — a location whose file changed since the response was produced is dropped
    /// rather than shown with garbage content.
    public static func searchMatch(for location: Location, url: URL, lines: [String]) -> SearchMatch? {
        let lineIndex = location.range.start.line
        guard lineIndex >= 0, lineIndex < lines.count else { return nil }
        let lineText = lines[lineIndex]
        // `range.end` is usually on the same line as `range.start` for a reference (an
        // identifier); if a server ever reports a multi-line range here, clamp the preview
        // highlight to the rest of the start line rather than reading into the next line's text.
        let start = location.range.start.character
        let end = location.range.end.line == lineIndex ? location.range.end.character : lineText.utf16.count
        let rangeInLine = min(start, end)..<max(start, end)
        return SearchMatch(file: url, lineNumber: lineIndex + 1, lineText: lineText, rangeInLine: rangeInLine)
    }

    /// Groups already-resolved `(url, match)` pairs by file, in first-seen order (server
    /// response order) — matching `ProjectSearchViewModel.groupedResults`'s own "no
    /// re-sorting, just group" behavior.
    public static func group(_ resolved: [(url: URL, match: SearchMatch)]) -> [FileMatchGroup] {
        var matchesByFile: [URL: [SearchMatch]] = [:]
        var fileOrder: [URL] = []
        for (url, match) in resolved {
            if matchesByFile[url] == nil { fileOrder.append(url) }
            matchesByFile[url, default: []].append(match)
        }
        return fileOrder.map { FileMatchGroup(file: $0, matches: matchesByFile[$0] ?? []) }
    }
}
