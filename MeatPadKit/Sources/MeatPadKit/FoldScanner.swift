import Foundation

/// A single foldable region: a "head" line whose subsequent lines are more
/// deeply indented, plus the indented "body" that would collapse under it.
public struct FoldRegion: Equatable, Sendable {
    public let headLineRange: Range<Int>   // UTF-16 range of the head line (excl. newline)
    public let bodyRange: Range<Int>       // UTF-16 range of the foldable body (head's newline .. last body line end)
    public let level: Int                  // nesting depth, 0-based
}

/// Finds indent-based fold regions in plain text, language-agnostically: no
/// knowledge of braces, keywords, or comments, just relative indentation.
/// Runs on every buffer edit to refresh the fold gutter, so it's a single
/// linear pass over the text's UTF-16 code units with no per-call regex.
public enum FoldScanner {

    /// - Parameters:
    ///   - text: the document text to scan.
    ///   - tabWidth: columns a leading tab counts as, for comparing indent depth.
    /// - Returns: fold regions sorted by head position. A region starts at a
    ///   line whose next non-blank line is more indented than it; the region
    ///   spans every subsequent line more indented than the head (blank lines
    ///   pass through without splitting the region), stopping before the next
    ///   line at or above the head's indent. Trailing blank lines are excluded.
    ///   Regions may nest; `level` is the nesting depth at that point.
    public static func regions(in text: String, tabWidth: Int = 4) -> [FoldRegion] {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return [] }

        // MARK: Split into lines (content range excluding any newline).
        struct Line {
            var start: Int
            var contentEnd: Int
        }
        var lines: [Line] = []
        var i = 0
        while i <= units.count {
            let start = i
            var contentEnd = start
            while contentEnd < units.count, units[contentEnd] != 10, units[contentEnd] != 13 {
                contentEnd += 1
            }
            lines.append(Line(start: start, contentEnd: contentEnd))
            if contentEnd >= units.count {
                break // last line, no trailing newline
            }
            // Consume the newline: "\r\n" counts as one, lone "\n" or "\r" too.
            if units[contentEnd] == 13, contentEnd + 1 < units.count, units[contentEnd + 1] == 10 {
                i = contentEnd + 2
            } else {
                i = contentEnd + 1
            }
        }

        // MARK: Per-line blank / indent classification.
        let isBlank: [Bool] = lines.map { line in
            for u in line.start..<line.contentEnd where u < units.count {
                if units[u] != 9 && units[u] != 32 { return false }
            }
            return true
        }
        let indent: [Int] = lines.enumerated().map { idx, line in
            guard !isBlank[idx] else { return 0 }
            var col = 0
            var u = line.start
            while u < line.contentEnd {
                if units[u] == 9 { col += tabWidth }
                else if units[u] == 32 { col += 1 }
                else { break }
                u += 1
            }
            return col
        }

        // Next non-blank line index, computed back-to-front.
        var nextNonBlank = [Int?](repeating: nil, count: lines.count)
        var next: Int? = nil
        for idx in stride(from: lines.count - 1, through: 0, by: -1) {
            nextNonBlank[idx] = next
            if !isBlank[idx] { next = idx }
        }

        // MARK: Single pass with a stack of open regions.
        struct Frame {
            let headIndex: Int
            let headIndent: Int
            let level: Int
            var lastBodyLineIndex: Int
        }
        var stack: [Frame] = []
        var results: [FoldRegion] = []

        func close(_ frame: Frame) {
            let headLine = lines[frame.headIndex]
            let lastBodyLine = lines[frame.lastBodyLineIndex]
            results.append(FoldRegion(
                headLineRange: headLine.start..<headLine.contentEnd,
                bodyRange: headLine.contentEnd..<lastBodyLine.contentEnd,
                level: frame.level
            ))
        }

        for idx in 0..<lines.count {
            guard !isBlank[idx] else { continue }
            let d = indent[idx]

            while let top = stack.last, top.headIndent >= d {
                close(top)
                stack.removeLast()
            }

            for frameIdx in stack.indices {
                stack[frameIdx].lastBodyLineIndex = idx
            }

            if let j = nextNonBlank[idx], indent[j] > d {
                stack.append(Frame(headIndex: idx, headIndent: d, level: stack.count, lastBodyLineIndex: idx))
            }
        }
        while let top = stack.last {
            close(top)
            stack.removeLast()
        }

        return results.sorted { $0.headLineRange.lowerBound < $1.headLineRange.lowerBound }
    }
}
