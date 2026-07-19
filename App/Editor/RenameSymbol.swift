import Foundation
import MeatPadKit
import LanguageServerProtocol

/// One in-flight Rename Symbol prompt (0.7 LSP plan Task 6) — `ProjectViewModel
/// .requestRenameSymbol` builds this after a successful `prepareRename`/fallback
/// word-lookup; `RenameSymbolSheet` reads it, `ProjectViewModel.performRename` consumes it.
/// `offset`/`position` are the same UTF-16 caret spot in two addressings: `offset` for
/// `RenameSymbol.caretAfterRename` (whole-document UTF-16), `position` for the
/// `RenameParams` LSP request itself (line/character).
struct RenameSymbolRequest: Identifiable {
    let id = UUID()
    let fileURL: URL
    let languageID: String
    let offset: Int
    let position: Position
    let defaultName: String
}

/// Rename Symbol (0.7 LSP plan Task 6): the app-side half of `WorkspaceEditApplier`
/// (`MeatPadKit`) — everything that needs `EditorRegistry`/disk IO, which the kit can't
/// see. `ProjectViewModel.requestRenameSymbol`/`performRename` own the request/response
/// round trips; this type is the pure-ish dispatch + apply step in between, split out for
/// the same reason `GoToDefinition`/`FindReferences` are their own files.
///
/// **Undo**: an OPEN file's rename goes through `FileEditorViewModel.text`, i.e.
/// `STTextView.text = newFullString` (`CodeEditor.updateNSView`'s existing text-binding
/// path — see `STTextView.setString`, which explicitly *disables* undo registration around
/// a whole-document replace). So a rename is **not** undoable with Cmd+Z, in the renamed
/// file or any other — same ceiling every other programmatic whole-buffer replace in this
/// app already has (initial load, revert, external-change reload), just newly reachable
/// from a live edit session instead of only from disk. A CLOSED file's rename never had an
/// undo stack to begin with (no editor is open on it) — its only "undo" is not having
/// saved yet, and this writes straight to disk. This is the documented v1 ceiling; a real
/// fix needs STTextView's per-edit-range replace API run once per (converted) edit inside
/// an explicit undo group, which the current whole-string `.text` setter path doesn't
/// give us — future work, not this pass.
enum RenameSymbol {
    struct FileResult {
        let url: URL
        let success: Bool
        let reason: String?
    }

    struct Outcome {
        let results: [FileResult]
        /// Caret offset (UTF-16, into the ORIGINATING file's new text) to restore after
        /// the rename — `nil` when that file's own edit didn't apply (so there's nothing
        /// sane to reveal) or the request didn't touch it at all.
        let originatingCaret: Int?
    }

    /// Applies every file in `edit`, one file at a time, each independently all-or-nothing
    /// (`WorkspaceEditApplier.apply`'s own contract) — one file's bad ranges never blocks
    /// or corrupts another's. A `WorkspaceEditDocumentChange` whose URI doesn't parse is
    /// dropped silently: no server this app talks to has ever been observed emitting one,
    /// and there's no sane filename to report it under.
    ///
    /// `originatingTextAtRequest`: the origin file's `vm.text` snapshot taken right before
    /// `textDocument/rename` was sent (see `ProjectViewModel.performRename`). `didChange` is
    /// debounced, so the server can compute edits against text that's already stale by the
    /// time this returns — a range that's still in-bounds but shifted would silently apply
    /// at the wrong offsets, and rename has no undo to recover with. Guarded the same way
    /// `LSPController.requestHover` guards its own round trip (`LSPController.swift`:
    /// `textView.text == text` before presenting) — capture, compare at apply time, drop if
    /// stale rather than guess. Only the origin file needs this: it's the only open file the
    /// user can be typing in during the round trip (single window, sheet-modal focus). Other
    /// open files touched by the same rename aren't covered by this guard — they could still
    /// be mutated by an external process/background watcher mid-round-trip; that exposure
    /// predates this fix and isn't new here.
    @MainActor
    static func apply(_ edit: WorkspaceEdit, originatingFile: URL, originatingOffset: Int, originatingTextAtRequest: String?) -> Outcome {
        let originating = originatingFile.standardizedFileURL
        var results: [FileResult] = []
        var originatingCaret: Int?

        for fileEdit in WorkspaceEditApplier.normalize(edit) {
            guard let url = URL(string: fileEdit.uri) else { continue }
            let isOriginating = url.standardizedFileURL == originating

            if isOriginating, let snapshot = originatingTextAtRequest,
               currentText(of: url) != snapshot {
                results.append(FileResult(
                    url: url, success: false,
                    reason: String(localized: "Skipped — this file changed while the rename was in progress.")
                ))
                continue
            }

            let (success, reason, caret) = applyToFile(
                url: url, edits: fileEdit.edits,
                captureCaretFrom: isOriginating ? originatingOffset : nil
            )
            results.append(FileResult(url: url, success: success, reason: reason))
            if isOriginating, success { originatingCaret = caret }
        }
        return Outcome(results: results, originatingCaret: originatingCaret)
    }

    /// Current buffer text for `url` if it's open — same "only trust `allFileViewModels`,
    /// never `fileViewModel(for:)`'s throwaway-creation path" rule `applyToFile` follows.
    @MainActor
    private static func currentText(of url: URL) -> String? {
        EditorRegistry.shared.allFileViewModels()
            .first { $0.document.url.standardizedFileURL == url.standardizedFileURL }?.text
    }

    /// One file's edits. `captureCaretFrom` is the pre-rename caret offset to translate
    /// through this file's own edits — passed only for the file the rename was invoked
    /// from; every other touched file has no caret to restore.
    ///
    /// OPEN (live in `EditorRegistry`, i.e. actually referenced by some editor pane right
    /// now — `EditorRegistry.fileViewModel(for:)` itself would happily *create* a
    /// throwaway VM for a closed file, so this checks `allFileViewModels()` instead, which
    /// only ever holds VMs something still keeps alive): apply through the VM's `text`, so
    /// the visible editor updates immediately and the dirty flag flips.
    /// CLOSED: read → apply → write back `.atomic`, matching `FileDocumentModel.save()`'s
    /// own write path. Not UTF-8 (or unreadable at all) → reported, not attempted.
    @MainActor
    private static func applyToFile(url: URL, edits: [TextEdit], captureCaretFrom originalCaret: Int?) -> (success: Bool, reason: String?, caret: Int?) {
        if let vm = EditorRegistry.shared.allFileViewModels().first(where: { $0.document.url.standardizedFileURL == url.standardizedFileURL }) {
            guard let newText = WorkspaceEditApplier.apply(edits, to: vm.text) else {
                return (false, String(localized: "Some edits no longer matched the file's current text."), nil)
            }
            // Caret math reads `vm.text` (the OLD text) — must run before it's overwritten.
            let caret = originalCaret.flatMap { caretAfterRename(originalCaret: $0, edits: edits, in: vm.text) }
            vm.text = newText
            return (true, nil, caret)
        }

        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            return (false, String(localized: "Couldn't read the file (missing, or not UTF-8)."), nil)
        }
        guard let newText = WorkspaceEditApplier.apply(edits, to: text) else {
            return (false, String(localized: "Some edits no longer matched the file's current text."), nil)
        }
        let caret = originalCaret.flatMap { caretAfterRename(originalCaret: $0, edits: edits, in: text) }
        do {
            try Data(newText.utf8).write(to: url, options: .atomic)
            return (true, nil, caret)
        } catch {
            return (false, error.localizedDescription, nil)
        }
    }

    /// Where the caret should land, in the NEW text, after `edits` apply to `originalText`
    /// — the edit whose original range contains `originalCaret` (or, failing that, the one
    /// whose start is nearest it) shifted by the net length delta of every edit before it
    /// in the document, landing at the end of that edit's own replacement text. Returns
    /// `nil` if any edit's range fails to convert (mirrors `WorkspaceEditApplier.apply`'s
    /// own bail-out — that file didn't apply either, in that case).
    static func caretAfterRename(originalCaret: Int, edits: [TextEdit], in originalText: String) -> Int? {
        struct Ranged { let range: NSRange; let newLength: Int }
        let ranged: [Ranged] = edits.compactMap {
            guard let range = LSPPositionBridge.nsRange(of: $0.range, in: originalText) else { return nil }
            return Ranged(range: range, newLength: ($0.newText as NSString).length)
        }
        guard ranged.count == edits.count, !ranged.isEmpty else { return nil }

        let sorted = ranged.sorted { $0.range.location < $1.range.location }
        let targetIndex = sorted.firstIndex(where: {
            $0.range.location <= originalCaret && originalCaret <= $0.range.location + $0.range.length
        }) ?? sorted.indices.min(by: {
            abs(sorted[$0].range.location - originalCaret) < abs(sorted[$1].range.location - originalCaret)
        })!

        var delta = 0
        for i in 0..<targetIndex {
            delta += sorted[i].newLength - sorted[i].range.length
        }
        let target = sorted[targetIndex]
        return target.range.location + delta + target.newLength
    }

    /// Identifier word (`[A-Za-z0-9_]+`) touching `caret` in `text`, as a range rather
    /// than the substring `EditorCommandContext.word(in:at:)` (same character class)
    /// returns — the `prepareRename` fallback and the "no server support" path both need
    /// the range, to confirm there's something there and to read its exact text.
    static func wordRange(in text: NSString, at caret: Int) -> NSRange? {
        func isWord(_ c: unichar) -> Bool {
            (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
        }
        guard text.length > 0 else { return nil }
        var start = min(max(caret, 0), text.length), end = start
        while start > 0, isWord(text.character(at: start - 1)) { start -= 1 }
        while end < text.length, isWord(text.character(at: end)) { end += 1 }
        return start < end ? NSRange(location: start, length: end - start) : nil
    }

    /// Resolves a *successful, non-nil* `prepareRename` response into a target range +
    /// default prompt text. The three response shapes: a bare `LSPRange` (use it, read the
    /// text under it as the default name); a `RangeWithPlaceholder` (use its own
    /// server-suggested name instead of re-reading the buffer); or `defaultBehavior: true`
    /// (the server explicitly hands word-boundary detection back to the client — same
    /// `wordRange` fallback the "no `prepareRename` support at all" path already uses).
    /// `nil` here means the response's own range didn't convert against `text` — same
    /// "abort, don't guess" contract as `WorkspaceEditApplier`.
    static func target(from response: ThreeTypeOption<LSPRange, RangeWithPlaceholder, PrepareRenameDefaultBehavior>, position: Position, text: String) -> (range: NSRange, name: String)? {
        switch response {
        case .optionA(let range):
            guard let nsRange = LSPPositionBridge.nsRange(of: range, in: text), nsRange.length > 0 else { return nil }
            return (nsRange, (text as NSString).substring(with: nsRange))
        case .optionB(let withPlaceholder):
            guard let nsRange = LSPPositionBridge.nsRange(of: withPlaceholder.range, in: text) else { return nil }
            return (nsRange, withPlaceholder.placeholder)
        case .optionC:
            guard let offset = LSPPositionBridge.offset(of: position, in: text),
                  let range = wordRange(in: text as NSString, at: offset) else { return nil }
            return (range, (text as NSString).substring(with: range))
        }
    }
}
