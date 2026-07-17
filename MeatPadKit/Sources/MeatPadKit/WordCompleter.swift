import Foundation

/// Completes a partially-typed word using other word-like runs already
/// present in the document text, ranked by proximity to the caret. This runs
/// on every keystroke while a completion popup is open, so it does a single
/// linear scan over the text's UTF-16 code units with no per-call regex
/// allocation.
public enum WordCompleter {

    /// - Parameters:
    ///   - prefix: the partial word already typed. Empty prefix yields no candidates.
    ///   - text: the document text to scan for word-like runs (`[A-Za-z_][A-Za-z0-9_]*`).
    ///   - caretOffset: caret position as a UTF-16 offset into `text`.
    ///   - limit: maximum number of candidates to return.
    /// - Returns: candidate words matching `prefix` case-insensitively, excluding
    ///   the word currently being typed at the caret and any word equal to
    ///   `prefix`, ranked by UTF-16 distance of their nearest occurrence to
    ///   `caretOffset` (ascending; exact-case matches beat case-folded ones at
    ///   equal distance), deduped to each word's nearest occurrence.
    public static func complete(prefix: String, in text: String, caretOffset: Int, limit: Int = 20) -> [String] {
        guard !prefix.isEmpty else { return [] }

        let units = Array(text.utf16)
        let lowerPrefix = prefix.lowercased()

        var bestDistance: [String: Int] = [:]
        var order: [String] = []

        var i = 0
        while i < units.count {
            guard isWordStart(units[i]) else { i += 1; continue }
            let start = i
            i += 1
            while i < units.count, isWordContinue(units[i]) { i += 1 }
            let end = i

            if caretOffset >= start && caretOffset <= end { continue } // word being typed

            let word = String(decoding: units[start..<end], as: UTF16.self)
            if word == prefix { continue }
            guard word.lowercased().hasPrefix(lowerPrefix) else { continue }

            // Distance to the word's nearest edge, not its start — a long word
            // fully before the caret is only as far as its end, not its start.
            let distance = caretOffset < start ? start - caretOffset : caretOffset - end
            if let existing = bestDistance[word] {
                if distance < existing { bestDistance[word] = distance }
            } else {
                bestDistance[word] = distance
                order.append(word)
            }
        }

        // Stable sort: distance ascending, exact-case match before case-folded
        // at equal distance, otherwise first-encountered order is preserved.
        let ranked = order.sorted { a, b in
            let da = bestDistance[a]!
            let db = bestDistance[b]!
            if da != db { return da < db }
            let aExact = a.hasPrefix(prefix)
            let bExact = b.hasPrefix(prefix)
            if aExact != bExact { return aExact }
            return false
        }

        return Array(ranked.prefix(limit))
    }

    private static func isWordStart(_ unit: UInt16) -> Bool {
        (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95 // A-Z a-z _
    }

    private static func isWordContinue(_ unit: UInt16) -> Bool {
        isWordStart(unit) || (unit >= 48 && unit <= 57) // + 0-9
    }
}
