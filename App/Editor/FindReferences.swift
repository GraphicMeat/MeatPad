import Foundation
import LanguageServerProtocol
import MeatPadKit

/// Find References (0.7 LSP plan Task 5): `textDocument/references` response → grouped-by-
/// file preview rows. The pure grouping/line-math (`FindReferences.searchMatch`/`.group`)
/// lives in MeatPadKit; this extension adds the one impure step — resolving a location's
/// line text from the live buffer or disk — which needs `EditorRegistry` (App-only state).
/// Deliberately NOT folded into `LSPController` (single-editor scoped) or `GoToDefinition`
/// (unrelated response shape) — see those types' own doc comments for the split rationale
/// this follows.
extension FindReferences {
    /// One `Location` → one `SearchMatch` line preview, grouped by file in first-seen
    /// (server response) order. Reads the line from the open buffer (`EditorRegistry`) when
    /// the file has one, otherwise a fresh disk read — same "live buffer wins, disk is the
    /// fallback" rule `ProjectViewModel.navigateToDefinition` uses. A location whose file
    /// can't be read, or whose start line is out of range for the resolved text, is dropped
    /// rather than shown with garbage content.
    @MainActor
    static func groupedMatches(from locations: [Location]) -> [FileMatchGroup] {
        var resolved: [(url: URL, match: SearchMatch)] = []
        for location in locations {
            guard let url = URL(string: location.uri),
                  let text = EditorRegistry.shared.fileViewModel(for: url)?.text
                      ?? (try? String(contentsOf: url, encoding: .utf8))
            else { continue }
            let lines = text.components(separatedBy: "\n")
            guard let match = FindReferences.searchMatch(for: location, url: url, lines: lines) else { continue }
            resolved.append((url, match))
        }
        return FindReferences.group(resolved)
    }
}
