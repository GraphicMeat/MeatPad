import AppKit
import MeatPadKit
import STTextView
import LanguageServerProtocol

/// One row in the Ctrl+Space popup. `STCompletionItem` only requires an `NSView` to display
/// plus `Identifiable` — a bare word is its own id, since `WordCompleter` already dedupes its
/// results to one candidate per word.
struct WordCompletionItem: STCompletionItem {
    let id: String
    var view: NSView { NSTextField(labelWithString: id) }

    init(_ word: String) { self.id = word }
}

/// A snippet-trigger row (merge source 4): visually distinct from a plain word — trigger
/// plus the snippet's name as a secondary hint, Xcode-completion style — so the user can
/// tell accepting it will expand a template rather than insert a bare identifier.
/// Accepting one runs `SnippetController.acceptCompletion`, the same expansion core
/// `handleTab`/`insert` use.
struct SnippetCompletionItem: STCompletionItem {
    let id: String
    // Qualified: `LanguageServerProtocol` (imported below for `CompletionItem` et al.) has its
    // own unrelated `Snippet` type (LSP snippet-placeholder syntax), colliding with this app's
    // `MeatPadKit.Snippet` (a saved snippet-library entry) on bare name lookup.
    let snippet: MeatPadKit.Snippet

    init(_ snippet: MeatPadKit.Snippet) {
        self.snippet = snippet
        self.id = "snippet:\(snippet.id)"
    }

    var view: NSView {
        let field = NSTextField(labelWithString: "")
        let text = NSMutableAttributedString(
            string: snippet.trigger,
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
        )
        text.append(NSAttributedString(
            string: "  \(snippet.name)",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor]
        ))
        field.attributedStringValue = text
        return field
    }
}

/// LSP completion row (merge source 0, when a server is alive for this doc's language — see
/// `CodeEditor.Coordinator.lspHandle`). Rendered the same two-part-`NSAttributedString` way as
/// `SnippetCompletionItem`, with a third leading part: a one-letter kind glyph so a method/
/// function reads differently from a keyword or a variable at a glance, Xcode-completion style,
/// without pulling in real SF Symbol images for 23 `CompletionItemKind` cases.
struct LSPCompletionItem: STCompletionItem {
    let id: String
    let item: CompletionItem

    /// `index` folds into `id` alongside the label. It isn't actually load-bearing for
    /// uniqueness: the merge loop that constructs these (`completionItemsAsync`) already dedups
    /// LSP results by label via `seen.insert(lspItem.label)` before appending, so two
    /// `LSPCompletionItem`s in the same list never share a label in the first place — `index` is
    /// just cheap insurance against a future caller that skips that dedup.
    init(_ item: CompletionItem, index: Int) {
        self.item = item
        self.id = "lsp:\(index):\(item.label)"
    }

    var view: NSView {
        let field = NSTextField(labelWithString: "")
        let (glyph, color) = Self.glyph(for: item.kind)
        let text = NSMutableAttributedString(
            string: "\(glyph) ",
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .bold), .foregroundColor: color]
        )
        text.append(NSAttributedString(
            string: item.label,
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
        ))
        if let detail = item.detail, !detail.isEmpty {
            text.append(NSAttributedString(
                string: "  \(detail)",
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor]
            ))
        }
        field.attributedStringValue = text
        return field
    }

    /// Coarse kind → (letter, tint) buckets, loosely matching Xcode's completion-icon color
    /// coding (callables purple, members blue, types orange) without needing per-kind SF
    /// Symbol art for all 23 `CompletionItemKind` cases.
    private static func glyph(for kind: CompletionItemKind?) -> (String, NSColor) {
        switch kind {
        case .method, .function, .constructor: return ("ƒ", .systemPurple)
        case .field, .property, .variable, .constant: return ("v", .systemBlue)
        case .class, .struct, .interface, .enum: return ("c", .systemOrange)
        case .enumMember: return ("e", .systemOrange)
        case .keyword: return ("k", .systemPink)
        case .snippet: return ("s", .systemGreen)
        default: return ("•", .secondaryLabelColor)
        }
    }
}

/// STCompletionViewController (the popup's built-in list) leaves the table with nothing
/// selected until the user presses an arrow key — so an immediate Return/Tab/click would do
/// nothing — and only accepts on double-click. This subclass selects row 0 whenever the
/// candidate list changes (initial show and every live refilter) and promotes a single click
/// to accept, matching the brief's "↓/↑ move, click accepts" behaviour.
final class WordCompletionViewController: STCompletionViewController {
    override var items: [any STCompletionItem] {
        didSet {
            if !items.isEmpty {
                tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            }
        }
    }

    override func tableViewAction(_ sender: Any?) {
        guard tableView.selectedRow != -1 else { return }
        delegate?.completionViewController(self, complete: items[tableView.selectedRow], movement: .other)
        cancelOperation(self)
    }
}

/// Drives Ctrl+Space word completion for one editor. Uses STTextView 2.3.10's built-in
/// completion facility (`STTextView.complete(_:)` + `STCompletionItem`/`STCompletionViewController`)
/// rather than a bespoke NSPanel: it already anchors a borderless popup window at the caret's
/// screen rect via `textLayoutManager.textSegmentFrame`, and — because the popup window's
/// `canBecomeKey` is `false` and it instead runs a local `NSEvent` key-down monitor — it
/// already intercepts ↓/↑ (moves the table selection), Tab/Return (accept), and Esc (cancel)
/// *before* those key-down events ever reach this text view's own key-command overrides. So
/// none of that routing needs to be reimplemented here; only the two content hooks
/// (`completionItemsAtLocation` / `insertCompletionItem`) and a resync policy for live typing
/// are ours to provide, both forwarded here from `CodeEditor.Coordinator`.
@MainActor final class CompletionController {
    /// Word-run range currently being completed. Set in `completionItems(textView:)` (the
    /// single place a prefix is computed), consumed by `insertCompletionItem` — so acceptance
    /// always replaces exactly the run that produced the shown candidates, regardless of
    /// which key or click triggered it.
    private var prefixRange: NSRange?

    /// Ctrl+Space. `complete(_:)` drives everything else: it calls back into
    /// `completionItems(textView:)` below for candidates, and shows/positions the popup.
    func trigger(textView: STTextView) {
        // No word-completion popup while multiple carets are active — there's no single prefix.
        guard !MultiCaretController.hasMultipleSelections(textView) else { return }
        textView.complete(nil)
    }

    /// Called from the editor's textDidChange/didChangeSelection hooks whenever the popup
    /// might need to react to what just happened. No-op unless the popup is already showing.
    ///
    /// STTextView ships a `shouldDimissCompletionOnSelectionChange` heuristic for this, but it
    /// only keeps the popup open across a selection change caused by typing a *letter* — completing
    /// an identifier with a digit or underscore (`utf8`, `my_var`) would otherwise close it
    /// mid-word. `CodeEditor` disables that heuristic and relies on this instead: still inside
    /// a word run → refilter; caret left word context entirely (space, click elsewhere,
    /// arrow out of the word, scroll-triggered jump) → dismiss.
    func syncPopup(textView: STTextView) {
        guard textView.isCompletionActive else { return }
        if wordRange(textView: textView) != nil {
            textView.complete(nil)
        } else {
            textView.cancelComplete(nil)
        }
    }

    // MARK: STTextViewDelegate forwarding (called by CodeEditor.Coordinator)

    /// Total popup cap after merging all sources (unchanged from the pre-merge single-source
    /// limit — sections share it in priority order below).
    private static let cap = 20

    /// Merges candidates in priority order — current document, project-wide identifiers,
    /// language keywords, snippet triggers — sharing one 20-row cap. Dedup is first-source-wins
    /// (a word already added by a higher-priority source is skipped by a later one); a candidate
    /// equal to the typed prefix is always excluded, matching the pre-merge single-source rule.
    /// `symbolIndex`/`currentFileURL` are `nil` for notes and other project-less surfaces, which
    /// silently drops source 2 and leaves 1/3/4 exactly as they'd behave standalone.
    func completionItems(
        textView: STTextView,
        languageID: String?,
        symbolIndex: ProjectSymbolIndex?,
        currentFileURL: URL?,
        snippetController: SnippetController?
    ) -> [any STCompletionItem]? {
        guard let (range, prefix) = wordRange(textView: textView) else { return nil }
        prefixRange = range

        var items: [any STCompletionItem] = []
        var seen = Set<String>()
        appendLocalSources(
            prefix: prefix, range: range, textView: textView, languageID: languageID,
            symbolIndex: symbolIndex, currentFileURL: currentFileURL, snippetController: snippetController,
            items: &items, seen: &seen
        )
        return items.isEmpty ? nil : items
    }

    /// LSP-aware variant of `completionItems`, called only from STTextView's *async* completion
    /// delegate hook (`CodeEditor.Coordinator` routes into this whenever a server is alive for
    /// the doc's language — see that type's `lspHandle`; the sync hook above handles every other
    /// case unchanged). Races `textDocument/completion` against a 150ms budget — "simpler: race
    /// with 150ms cap, take whichever's ready" per the 0.7 LSP plan's Task 2 — so a hung or slow
    /// server can never delay the always-local sources 1-4 beyond that bound. The loser is
    /// cancelled; if that's the LSP request, its eventual (unused) result is simply dropped.
    ///
    /// No separate staleness check is needed on the response: the fork's own
    /// `isValidCompletionRequest` (STTextView+Complete.swift) re-validates the caret/selection
    /// snapshot after this returns and silently discards the whole result if the user kept
    /// typing while the request was in flight (Global Constraints' "responses validated against
    /// current buffer generation" — this is that validation, built into the fork already).
    func completionItemsAsync(
        textView: STTextView,
        languageID: String?,
        symbolIndex: ProjectSymbolIndex?,
        currentFileURL: URL?,
        snippetController: SnippetController?,
        lspHandle: LSPServerHandle?,
        fileURL: URL?
    ) async -> [any STCompletionItem]? {
        guard let (range, prefix) = wordRange(textView: textView) else { return nil }
        prefixRange = range

        var items: [any STCompletionItem] = []
        var seen = Set<String>()

        // 0. LSP — leads the popup, ahead of every local source. Server results may ignore our
        // prefix entirely, so filter client-side the same way source 3 (keywords) already does;
        // sorted by `sortText` (falling back to `label`, the LSP-recommended tiebreak) so the
        // server's own ranking survives the merge.
        if let lspHandle, let fileURL, let text = textView.text,
           let position = LSPPositionBridge.position(of: range.upperBound, in: text) {
            let params = CompletionParams(uri: fileURL.absoluteString, position: position, triggerKind: .invoked, triggerCharacter: nil)
            let lowerPrefix = prefix.lowercased()
            let lspItems = await Self.requestCompletions(handle: lspHandle, params: params)
                .filter { $0.label.lowercased().hasPrefix(lowerPrefix) }
                .sorted { ($0.sortText ?? $0.label) < ($1.sortText ?? $1.label) }
            for (index, lspItem) in lspItems.enumerated() {
                guard items.count < Self.cap else { break }
                guard lspItem.label != prefix, seen.insert(lspItem.label).inserted else { continue }
                items.append(LSPCompletionItem(lspItem, index: index))
            }
        }

        appendLocalSources(
            prefix: prefix, range: range, textView: textView, languageID: languageID,
            symbolIndex: symbolIndex, currentFileURL: currentFileURL, snippetController: snippetController,
            items: &items, seen: &seen
        )
        return items.isEmpty ? nil : items
    }

    /// Races `handle.completion(params)` against a 150ms sleep and returns whichever finishes
    /// first: the server's items on a normal response, or `[]` on timeout, request failure, or
    /// an empty/absent response. `cancelAll()` cancels the loser — almost always the LSP request
    /// itself, on a hung server — without waiting for it any further.
    private static func requestCompletions(handle: LSPServerHandle, params: CompletionParams) async -> [CompletionItem] {
        await withTaskGroup(of: [CompletionItem]?.self) { group in
            group.addTask {
                (try? await handle.completion(params))?.items
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 150_000_000)
                return nil
            }
            let winner = await group.next() ?? nil
            group.cancelAll()
            return winner ?? []
        }
    }

    /// Merge sources 1-4 (current document, project identifiers, language keywords, snippet
    /// triggers) into `items`/`seen`, stopping at the shared cap. Identical for every caller —
    /// the plain sync path above and the LSP async path both funnel through here, so "server
    /// absent" behavior is guaranteed byte-for-byte unchanged from before LSP completion existed
    /// (same code, not just equivalent code).
    private func appendLocalSources(
        prefix: String,
        range: NSRange,
        textView: STTextView,
        languageID: String?,
        symbolIndex: ProjectSymbolIndex?,
        currentFileURL: URL?,
        snippetController: SnippetController?,
        items: inout [any STCompletionItem],
        seen: inout Set<String>
    ) {
        // Appends `word` as a plain completion row unless it's the typed prefix itself or a
        // dup of an earlier source's candidate. Returns false once the cap is hit, so each
        // source loop below can stop scanning as soon as there's no room left.
        func addWord(_ word: String) -> Bool {
            guard items.count < Self.cap else { return false }
            if word != prefix, seen.insert(word).inserted {
                items.append(WordCompletionItem(word))
            }
            return items.count < Self.cap
        }

        // 1. Current document — existing WordCompleter, caret-distance ranked.
        for word in WordCompleter.complete(prefix: prefix, in: textView.text ?? "", caretOffset: range.upperBound, limit: Self.cap) {
            if !addWord(word) { break }
        }

        // 2. Project-wide identifiers — frequency ranked, this file's solo contribution excluded
        // (its own words are already covered by source 1).
        if items.count < Self.cap, let symbolIndex {
            for word in symbolIndex.complete(prefix: prefix, excludingFile: currentFileURL, limit: Self.cap - items.count) {
                if !addWord(word) { break }
            }
        }

        // 3. Language keywords — prefix-filtered case-insensitively (LanguageKeywords returns
        // pre-sorted, deduped tables; empty for markup/data languages and unknown ids).
        if items.count < Self.cap, let languageID {
            let lowerPrefix = prefix.lowercased()
            for word in LanguageKeywords.keywords(for: languageID) where word.lowercased().hasPrefix(lowerPrefix) {
                if !addWord(word) { break }
            }
        }

        // 4. Snippet triggers — language-scoped, rendered as a distinct row (see
        // SnippetCompletionItem). Dedup shares the same `seen` set as the word sources so a
        // trigger that collides with an already-listed word isn't shown twice.
        if items.count < Self.cap, let snippetController {
            for snippet in snippetController.completionCandidates(prefix: prefix, languageID: languageID) {
                guard items.count < Self.cap else { break }
                guard seen.insert(snippet.trigger).inserted else { continue }
                items.append(SnippetCompletionItem(snippet))
            }
        }
    }

    func insertCompletionItem(_ item: any STCompletionItem, textView: STTextView, snippetController: SnippetController?) {
        guard let range = prefixRange else { return }
        prefixRange = nil
        if let snippetItem = item as? SnippetCompletionItem {
            snippetController?.acceptCompletion(snippetItem.snippet, replacing: range, textView: textView)
            return
        }
        if let lspItem = item as? LSPCompletionItem {
            insertLSPCompletion(lspItem.item, replacing: range, textView: textView)
            return
        }
        guard let word = (item as? WordCompletionItem)?.id else { return }
        textView.insertText(word, replacementRange: range)
    }

    /// Applies the server's `textEdit` — translated to a live-buffer `NSRange` via
    /// `LSPPositionBridge` — when present and still resolvable against the current text;
    /// otherwise falls back to `insertText`/the plain label at the tracked prefix range, same
    /// as the plain-word path just above. Covers "fall back to plain word insert on anything
    /// odd" per the plan: a stale/out-of-bounds `textEdit` range (edited since the request was
    /// sent) silently degrades to a plain insert rather than corrupting the buffer.
    ///
    /// Either payload is run through `plainText(from:format:)` first, so an
    /// `insertTextFormat == .snippet` item (sourcekit-lsp sends these routinely for function/
    /// method completions, e.g. `foo(${1:x: Int})$0`) never lands its raw TextMate syntax in
    /// the buffer.
    private func insertLSPCompletion(_ item: CompletionItem, replacing range: NSRange, textView: STTextView) {
        if let textEdit = item.textEdit, let text = textView.text {
            let lspRange: LSPRange
            let rawText: String
            switch textEdit {
            case .optionA(let edit):
                lspRange = edit.range
                rawText = edit.newText
            case .optionB(let edit):
                lspRange = edit.insert
                rawText = edit.newText
            }
            if let nsRange = LSPPositionBridge.nsRange(of: lspRange, in: text) {
                textView.insertText(Self.plainText(from: rawText, format: item.insertTextFormat), replacementRange: nsRange)
                return
            }
        }
        textView.insertText(Self.plainText(from: item.insertText ?? item.label, format: item.insertTextFormat), replacementRange: range)
    }

    /// ponytail: a `.snippet`-format payload (`$1`, `${1:default}`, `$0` tab stops) is flattened
    /// to plain text — literal spans plus each placeholder's default, bare stop markers dropped —
    /// not expanded into a real tab-stop session, so the caret just lands at the end of the
    /// insert rather than at the first placeholder. That's LSP's own snippet syntax, unrelated to
    /// `SnippetController`'s, but `MeatPadKit.SnippetParser` already parses the same `$N`/
    /// `${N:default}` grammar, so it does the parsing here too. Wire the flattened nodes through
    /// `SnippetController`'s tab-stop machinery instead if losing tab stops on LSP completions
    /// turns out to bother users in practice. An unparseable payload (regex transforms, a stray
    /// unbalanced brace) falls back to the raw string untouched, same "fall back on anything odd"
    /// policy as the textEdit-range fallback above.
    private static func plainText(from raw: String, format: InsertTextFormat?) -> String {
        guard format == .snippet, let parsed = try? SnippetParser.parse(raw) else { return raw }
        return flatten(parsed.nodes)
    }

    private static func flatten(_ nodes: [SnippetNode]) -> String {
        nodes.map { node in
            switch node {
            case .text(let text): return text
            case .tabStop(_, let placeholder): return flatten(placeholder)
            }
        }.joined()
    }

    // MARK: Trigger-word scan (same word-run rule as SnippetController.triggerMatch)

    /// The `[A-Za-z0-9_]+` run ending at a plain caret. All word characters are ASCII (single
    /// UTF-16 code units), so scanning code units is safe.
    private func wordRange(textView: STTextView) -> (NSRange, String)? {
        let selection = textView.textSelection
        guard selection.length == 0 else { return nil }
        let text = (textView.text ?? "") as NSString
        let caret = selection.location
        guard caret <= text.length else { return nil }

        var start = caret
        while start > 0, Self.isWordCharacter(text.character(at: start - 1)) {
            start -= 1
        }
        guard start < caret else { return nil }

        let range = NSRange(location: start, length: caret - start)
        return (range, text.substring(with: range))
    }

    private static func isWordCharacter(_ c: unichar) -> Bool {
        (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
    }
}
