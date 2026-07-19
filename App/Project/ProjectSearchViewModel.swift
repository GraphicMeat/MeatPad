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
    @Published var isRegex = false {
        didSet {
            // \b is regex syntax's job now; drop the flag rather than leaving a lit-but-
            // disabled toggle behind. (Its own didSet harmlessly re-schedules.)
            if isRegex { wholeWord = false }
            scheduleSearch()
        }
    }
    @Published var caseSensitive = false { didSet { scheduleSearch() } }
    @Published var wholeWord = false { didSet { scheduleSearch() } }
    @Published private(set) var results: [SearchMatch] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var isSearching = false
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
            isSearching = false
            return
        }

        let searchQuery = SearchQuery(pattern: query, isRegex: isRegex, caseSensitive: caseSensitive, wholeWord: wholeWord)
        isSearching = true
        searchTask = Task { [weak self, engine, root] in
            // A short debounce keeps typing fluid without making search feel delayed.
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled else { return }
            do {
                // NativeSearch hops files itself (concurrent task group); this await just
                // suspends the caller, it doesn't block the main actor.
                let matches = try await engine.search(searchQuery, in: root)
                guard !Task.isCancelled else { return }
                self?.results = matches
                self?.lastQuery = searchQuery
                self?.isSearching = false
            } catch {
                guard !Task.isCancelled else { return }
                self?.results = []
                self?.lastQuery = nil
                self?.errorMessage = error.localizedDescription
                self?.isSearching = false
            }
        }
    }

    /// Converts a match's line/column into a whole-document UTF-16 `NSRange` against the
    /// file's CURRENT contents (the shared `FileEditorViewModel` buffer if open elsewhere,
    /// disk otherwise) — the file may have changed since the search ran. Returns `nil` if
    /// the recorded line vanished or changed (caller opens without revealing then).
    static func revealRange(for match: SearchMatch) -> NSRange? {
        guard let text = EditorRegistry.shared.fileViewModel(for: match.file)?.text else { return nil }
        let lines = text.components(separatedBy: "\n")
        let idx = match.lineNumber - 1
        guard idx >= 0, idx < lines.count, lines[idx] == match.lineText else { return nil }

        var offset = 0
        for i in 0..<idx { offset += (lines[i] as NSString).length + 1 } // +1 per "\n"
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
        let dirtyFiles = Set(byFile.keys.filter { EditorRegistry.shared.fileViewModel(for: $0)?.isDirty == true })
        // SearchReplacer skips disk-stale files itself but only reports a count; running
        // the same predicate here tells us WHICH files those are, so the revert loop
        // below never touches a file the replacer didn't rewrite (a stale file's disk
        // divergence stays with the existing changed-on-disk banner flow instead).
        let staleFiles = Set(byFile.keys.filter { file in
            guard !dirtyFiles.contains(file) else { return false }
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { return true }
            let lines = content.components(separatedBy: "\n")
            return byFile[file]!.contains { match in
                let idx = match.lineNumber - 1
                return idx < 0 || idx >= lines.count || lines[idx] != match.lineText
            }
        })
        let matchesToReplace = results.filter { !dirtyFiles.contains($0.file) && !staleFiles.contains($0.file) }

        let confirm = NSAlert()
        confirm.messageText = results.count == 1
            ? String(localized: "Replace 1 match in 1 file?")
            : String(localized: "Replace \(results.count) matches in \(byFile.count) files?")
        if !dirtyFiles.isEmpty {
            confirm.informativeText = dirtyFiles.count == 1
                ? String(localized: "1 file has unsaved edits and will be skipped.")
                : String(localized: "\(dirtyFiles.count) files have unsaved edits and will be skipped.")
        }
        confirm.addButton(withTitle: String(localized: "Replace"))
        confirm.addButton(withTitle: String(localized: "Cancel"))
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
            alert.messageText = String(localized: "Replace failed.")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: String(localized: "OK"))
            alert.runModal()
        }
    }

    private func showSummary(replaced: Int, skipped: Int) {
        let alert = NSAlert()
        alert.messageText = replaced == 1
            ? String(localized: "Replaced 1 match.")
            : String(localized: "Replaced \(replaced) matches.")
        if skipped > 0 {
            alert.informativeText = skipped == 1
                ? String(localized: "1 match skipped.")
                : String(localized: "\(skipped) matches skipped.")
        }
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }
}
