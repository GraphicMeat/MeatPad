import AppKit
import MeatPadKit
import STTextView

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
    let snippet: Snippet

    init(_ snippet: Snippet) {
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

        return items.isEmpty ? nil : items
    }

    func insertCompletionItem(_ item: any STCompletionItem, textView: STTextView, snippetController: SnippetController?) {
        guard let range = prefixRange else { return }
        prefixRange = nil
        if let snippetItem = item as? SnippetCompletionItem {
            snippetController?.acceptCompletion(snippetItem.snippet, replacing: range, textView: textView)
            return
        }
        guard let word = (item as? WordCompletionItem)?.id else { return }
        textView.insertText(word, replacementRange: range)
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
