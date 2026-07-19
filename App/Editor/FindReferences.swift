import Foundation
import LanguageServerProtocol
import MeatPadKit

/// Find References (0.7 LSP plan Task 5): `textDocument/references` response → grouped-by-
/// file preview rows. Reuses `SearchMatch`/`FileMatchGroup` (`ProjectSearchViewModel.swift`)
/// rather than inventing a parallel row type, so `ReferencesView` can share `ProjectSearchView`'s
/// DisclosureGroup shape (`ProjectSearchView.swift:94-111`) and even its row-open logic
/// (`ProjectSearchViewModel.revealRange` — generic over any `SearchMatch`, not search-specific).
/// Deliberately NOT folded into `LSPController` (single-editor scoped) or `GoToDefinition`
/// (unrelated response shape) — see those types' own doc comments for the split rationale
/// this follows.
enum FindReferences {
    /// One `Location` → one `SearchMatch` line preview. Reads the line from the open buffer
    /// (`EditorRegistry`) when the file has one, otherwise a fresh disk read — same
    /// "live buffer wins, disk is the fallback" rule `ProjectViewModel.navigateToDefinition`
    /// uses. A location whose file can't be read, or whose start line is out of range for the
    /// resolved text, is dropped rather than shown with garbage content. Locations are grouped
    /// in first-seen file order (server response order), matching `ProjectSearchViewModel
    /// .groupedResults`'s own "no re-sorting, just group" behavior.
    @MainActor
    static func groupedMatches(from locations: [Location]) -> [FileMatchGroup] {
        var matchesByFile: [URL: [SearchMatch]] = [:]
        var fileOrder: [URL] = []
        for location in locations {
            guard let url = URL(string: location.uri), let match = searchMatch(for: location, url: url) else { continue }
            if matchesByFile[url] == nil { fileOrder.append(url) }
            matchesByFile[url, default: []].append(match)
        }
        return fileOrder.map { FileMatchGroup(file: $0, matches: matchesByFile[$0] ?? []) }
    }

    @MainActor
    private static func searchMatch(for location: Location, url: URL) -> SearchMatch? {
        guard let text = EditorRegistry.shared.fileViewModel(for: url)?.text
            ?? (try? String(contentsOf: url, encoding: .utf8)) else { return nil }
        let lines = text.components(separatedBy: "\n")
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
}
