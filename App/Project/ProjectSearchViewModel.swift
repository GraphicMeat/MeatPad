import Foundation
import AppKit
import MeatPadKit

/// One file's matches for the grouped results list.
struct FileMatchGroup: Identifiable {
    let file: URL
    var matches: [SearchMatch]
    var id: URL { file }
}

/// Backs the sidebar's "Search" mode (Cmd+Shift+F): debounced project-wide search over
/// `NativeSearch`, grouped results, and Replace All. One instance per `ProjectWindow`,
/// independent of `ProjectViewModel` — it only needs `root` to search and the shared
/// `EditorRegistry` to read/revert open buffers, not the tab/tree state.
@MainActor
final class ProjectSearchViewModel: ObservableObject {
    @Published var query = "" { didSet { scheduleSearch() } }
    @Published var replaceText = ""
    @Published var isRegex = false { didSet { scheduleSearch() } }
    @Published var caseSensitive = false { didSet { scheduleSearch() } }
    @Published var wholeWord = false { didSet { scheduleSearch() } }
    @Published private(set) var results: [SearchMatch] = []
    @Published private(set) var errorMessage: String?
    /// Bumped by the Cmd+Shift+F command to refocus the query field when the sidebar is
    /// already showing Search (a plain sidebar-mode switch can't re-trigger `.onAppear`).
    @Published private(set) var focusToken = UUID()

    private let root: URL
    private let engine: SearchEngine = NativeSearch()
    private var searchTask: Task<Void, Never>?
    /// The query that produced `results` — `replaceAll` needs the exact regex/case options
    /// the matches were found under, which may differ from in-flight (debounced) edits.
    private var lastQuery: SearchQuery?

    init(root: URL) {
        self.root = root
    }

    func requestFocus() {
        focusToken = UUID()
    }

    /// `results`, grouped by file and kept in the engine's own file/line sort order (no
    /// re-sorting needed — just a linear grouping pass).
    var groupedResults: [FileMatchGroup] {
        var groups: [FileMatchGroup] = []
        for match in results {
            if groups.isEmpty == false, groups[groups.count - 1].file == match.file {
                groups[groups.count - 1].matches.append(match)
            } else {
                groups.append(FileMatchGroup(file: match.file, matches: [match]))
            }
        }
        return groups
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        errorMessage = nil

        guard query.count >= 2 else {
            results = []
            lastQuery = nil
            return
        }

        let searchQuery = SearchQuery(pattern: query, isRegex: isRegex, caseSensitive: caseSensitive, wholeWord: wholeWord)
        searchTask = Task { [weak self, engine, root] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            do {
                // NativeSearch hops files itself (concurrent task group); this await just
                // suspends the caller, it doesn't block the main actor.
                let matches = try await engine.search(searchQuery, in: root)
                guard !Task.isCancelled else { return }
                self?.results = matches
                self?.lastQuery = searchQuery
            } catch {
                guard !Task.isCancelled else { return }
                self?.results = []
                self?.lastQuery = nil
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    /// Converts a match's line/column into a whole-document UTF-16 `NSRange` against the
    /// file's CURRENT contents (the shared `FileEditorViewModel` buffer if open elsewhere,
    /// disk otherwise) — the file may have changed since the search ran. Returns `nil` if
    /// the recorded line no longer exists or the match no longer fits on it.
    static func revealRange(for match: SearchMatch) -> NSRange? {
        guard let text = EditorRegistry.shared.fileViewModel(for: match.file)?.text else { return nil }
        let lines = text.components(separatedBy: "\n")
        let idx = match.lineNumber - 1
        guard idx >= 0, idx < lines.count else { return nil }

        var offset = 0
        for i in 0..<idx { offset += (lines[i] as NSString).length + 1 } // +1 per "\n"
        let lineLength = (lines[idx] as NSString).length
        guard match.rangeInLine.upperBound <= lineLength else { return nil }
        return NSRange(location: offset + match.rangeInLine.lowerBound, length: match.rangeInLine.count)
    }

    /// Confirms, replaces, and summarizes. Files with unsaved edits (`FileEditorViewModel
    /// .isDirty`) are excluded up front rather than left to `SearchReplacer`'s own staleness
    /// check — that check only compares against on-disk content, which a dirty (in-memory
    /// only) edit doesn't necessarily change, so it can't be relied on to protect unsaved
    /// work. Clean open buffers for touched files are reverted afterward so they pick up
    /// the replacement immediately, instead of waiting for the window to next become key.
    func replaceAll() {
        guard !results.isEmpty, let searchQuery = lastQuery else { return }

        let byFile = Dictionary(grouping: results, by: \.file)
        let dirtyFiles = byFile.keys.filter { EditorRegistry.shared.fileViewModel(for: $0)?.isDirty == true }
        let matchesToReplace = results.filter { !dirtyFiles.contains($0.file) }

        let confirm = NSAlert()
        confirm.messageText = "Replace \(results.count) match\(results.count == 1 ? "" : "es") in \(byFile.count) file\(byFile.count == 1 ? "" : "s")?"
        if !dirtyFiles.isEmpty {
            confirm.informativeText = "\(dirtyFiles.count) file\(dirtyFiles.count == 1 ? "" : "s") have unsaved edits and will be skipped."
        }
        confirm.addButton(withTitle: "Replace")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        guard matchesToReplace.isEmpty == false else {
            showSummary(replaced: 0, skipped: results.count)
            return
        }

        do {
            let (replaced, staleSkipped) = try SearchReplacer.replaceAll(matches: matchesToReplace, with: replaceText, query: searchQuery)
            for file in Set(matchesToReplace.map(\.file)) {
                if let vm = EditorRegistry.shared.fileViewModel(for: file), !vm.isDirty {
                    try? vm.revert()
                }
            }
            showSummary(replaced: replaced, skipped: staleSkipped + (results.count - matchesToReplace.count))
            scheduleSearch() // results are stale now
        } catch {
            let alert = NSAlert()
            alert.messageText = "Replace failed."
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func showSummary(replaced: Int, skipped: Int) {
        let alert = NSAlert()
        alert.messageText = "Replaced \(replaced) match\(replaced == 1 ? "" : "es")."
        if skipped > 0 {
            alert.informativeText = "\(skipped) match\(skipped == 1 ? "" : "es") skipped."
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
