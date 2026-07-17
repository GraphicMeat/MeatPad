import Foundation

/// Pure occurrence-search backing multi-caret "select next occurrence" (Cmd+D). Kept out
/// of the AppKit glue (`MultiCaretController`) so the wrap/skip logic is unit-testable.
public enum MultiCaret {
    /// Next occurrence of `needle` in `text` (case-sensitive), searching forward from
    /// `afterEnd` and wrapping to the start, skipping any occurrence whose start offset is
    /// already in `selectedStarts`. Returns nil when every occurrence is already selected (or
    /// none exist). Offsets are UTF-16 (NSString) units — the space STTextView selections live in.
    public static func nextMatch(in text: String, needle: String, afterEnd: Int, selectedStarts: Set<Int>) -> NSRange? {
        guard !needle.isEmpty else { return nil }
        let all = occurrences(of: needle, in: text as NSString)
        // Occurrences at/after the anchor's end first, then wrap to those before it.
        let ordered = all.filter { $0.location >= afterEnd } + all.filter { $0.location < afterEnd }
        return ordered.first { !selectedStarts.contains($0.location) }
    }

    private static func occurrences(of needle: String, in ns: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var start = 0
        while start <= ns.length {
            let found = ns.range(of: needle, options: [], range: NSRange(location: start, length: ns.length - start))
            guard found.location != NSNotFound else { break }
            result.append(found)
            start = found.location + max(1, found.length)
        }
        return result
    }
}
