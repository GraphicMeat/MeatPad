import AppKit
import MeatPadKit
import STTextView

/// Multi-caret selection logic for the editor: Cmd+D "select next occurrence", Option+Click
/// caret append, and Esc collapse. Stateless — everything derives from (and mutates)
/// `textView.textLayoutManager.textSelections`, which STTextView natively types/deletes across.
/// The key/mouse taps in `SnippetTextView` stay thin and route here.
@MainActor
enum MultiCaretController {
    /// True when more than one caret/range is active. Selections use either representation —
    /// multiple `NSTextSelection`s or one with multiple ranges — so count the ranges.
    static func hasMultipleSelections(_ textView: STTextView) -> Bool {
        textView.textLayoutManager.textSelections.reduce(0) { $0 + $1.textRanges.count } > 1
    }

    /// Cmd+D. No non-empty selection yet → select the word at the caret. Otherwise append the
    /// next occurrence (wrapping, case-sensitive) of the most-recent selection's text as an
    /// additional selection. Exhausted (every occurrence already selected) → beep-free no-op.
    static func selectNextOccurrence(in textView: STTextView) {
        let tlm = textView.textLayoutManager
        let cm = textView.textContentManager
        let nsRanges = tlm.textSelections.flatMap(\.textRanges).map { SnippetController.nsRange($0, in: cm) }
        let nonEmpty = nsRanges.filter { $0.length > 0 }
        let text = (textView.text ?? "") as NSString

        guard let anchor = nonEmpty.max(by: { $0.location < $1.location }) else {
            // Empty selection: select the word at the caret (first Cmd+D).
            let caret = textView.textSelection.location
            if let word = wordRange(in: text, at: caret) { textView.textSelection = word }
            return
        }

        let needle = text.substring(with: anchor)
        let selectedStarts = Set(nonEmpty.map(\.location))
        guard let next = MultiCaret.nextMatch(in: text as String, needle: needle, afterEnd: anchor.upperBound, selectedStarts: selectedStarts),
              let tr = textRange(next, cm) else { return }
        tlm.textSelections.append(NSTextSelection(range: tr, affinity: .downstream, granularity: .character))
        textView.needsLayout = true // viewport relayout redraws the new selection highlight + carets
    }

    /// Option+Click: `SnippetTextView` snapshots the pre-click selections, lets `super.mouseDown`
    /// place a single caret natively (correct point conversion, no gutter math), then calls this
    /// to prepend the previous selections back — a net append of one caret at the click.
    static func appendCaret(to textView: STTextView, keeping existing: [NSTextSelection]) {
        let tlm = textView.textLayoutManager
        tlm.textSelections = existing + tlm.textSelections
        textView.needsLayout = true
    }

    /// Esc with >1 caret/range: collapse to the first range. Returns true when it acted (so the
    /// tap consumes Esc), false when there was nothing to collapse (fall through to snippet/completion).
    static func collapseToFirst(_ textView: STTextView) -> Bool {
        let tlm = textView.textLayoutManager
        let ranges = tlm.textSelections.flatMap(\.textRanges)
        guard ranges.count > 1, let first = ranges.first else { return false }
        tlm.textSelections = [NSTextSelection(range: first, affinity: .downstream, granularity: .character)]
        textView.needsLayout = true
        return true
    }

    // MARK: - Helpers

    private static func wordRange(in text: NSString, at caret: Int) -> NSRange? {
        func isWord(_ c: unichar) -> Bool {
            (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
        }
        guard caret <= text.length else { return nil }
        var start = caret, end = caret
        while start > 0, isWord(text.character(at: start - 1)) { start -= 1 }
        while end < text.length, isWord(text.character(at: end)) { end += 1 }
        return start < end ? NSRange(location: start, length: end - start) : nil
    }

    private static func textRange(_ ns: NSRange, _ cm: NSTextContentManager) -> NSTextRange? {
        guard let start = cm.location(cm.documentRange.location, offsetBy: ns.location),
              let end = cm.location(start, offsetBy: ns.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }
}
