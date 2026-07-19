import Foundation
import LanguageServerProtocol

/// Converts between LSP `Position`/`LSPRange` (0-based line, UTF-16 code-unit offset within
/// the line) and whole-document UTF-16 offsets / `NSRange` — the same addressing NSString
/// and NSTextStorage use throughout MeatPad's editor. Pure Foundation, no AppKit, so it's
/// testable in the kit target.
///
/// Line splitting operates on UTF-16 code units directly, never `String.split(separator:)`
/// on `"\n"` as a `Character`: Swift's grapheme-cluster rules fold a CRLF pair into a
/// single `Character`, so a naive Character-based split silently refuses to split inside
/// "\r\n" and merges two LSP lines into one (verified: `"a\r\nb".split(separator: "\n")`
/// returns one element, not two). LSP counts "\n" as the only line separator — a "\r" (from
/// a CRLF or a lone CR) is just another UTF-16 unit on the line that precedes the break. So
/// `"a\r\nb"` is two lines: line 0 is `"a\r"` (2 units), line 1 is `"b"` (1 unit).
///
/// A UTF-16 offset that lands mid-surrogate-pair (e.g. `character: 1` into a line starting
/// with "😀") is always clamped back to the pair's start rather than rejected: LSP servers
/// occasionally emit sloppy offsets, and dropping an otherwise-valid response over one
/// split pair is worse than silently snapping to the nearest valid boundary — the same
/// behavior text editors use when clamping a caret off a surrogate pair.
public enum LSPPositionBridge {
    /// UTF-16 offset of the start of each line (index 0 is always 0). One more entry exists
    /// than there are "\n"s in `units` — the text after the final "\n" (or the whole text,
    /// if there's none) is always a line, even if empty.
    private static func lineStarts(units: [UInt16]) -> [Int] {
        var starts = [0]
        var offset = 0
        for unit in units {
            offset += 1
            if unit == 0x0A { starts.append(offset) }
        }
        return starts
    }

    /// If `offset` splits a surrogate pair (the unit at `offset` is a low surrogate and the
    /// unit before it is a high surrogate), steps back 1 to the pair's start. Otherwise
    /// returns `offset` unchanged.
    private static func clampSurrogateSplit(_ offset: Int, units: [UInt16]) -> Int {
        guard offset > 0, offset < units.count else { return offset }
        let isLowSurrogate = (0xDC00...0xDFFF).contains(units[offset])
        let precededByHighSurrogate = (0xD800...0xDBFF).contains(units[offset - 1])
        return isLowSurrogate && precededByHighSurrogate ? offset - 1 : offset
    }

    private static func lineLength(_ line: Int, starts: [Int], totalUTF16Count: Int) -> Int {
        if line + 1 < starts.count {
            return starts[line + 1] - starts[line] - 1 // exclude the trailing "\n"
        }
        return totalUTF16Count - starts[line]
    }

    /// Converts an LSP `Position` to a whole-document UTF-16 offset. `nil` if the line is
    /// out of bounds, or the character is negative or past the line's end (character may
    /// equal the line's UTF-16 length — the end-of-line position — but no more). The result
    /// is clamped off a split surrogate pair — see the clamp policy above.
    public static func offset(of position: Position, in text: String) -> Int? {
        let units = Array(text.utf16)
        let starts = lineStarts(units: units)
        guard position.line >= 0, position.line < starts.count else { return nil }
        let length = lineLength(position.line, starts: starts, totalUTF16Count: units.count)
        guard position.character >= 0, position.character <= length else { return nil }
        return clampSurrogateSplit(starts[position.line] + position.character, units: units)
    }

    /// Converts a whole-document UTF-16 offset to an LSP `Position`. `nil` if `utf16Offset`
    /// is negative or past the end of `text`. A mid-surrogate-pair `utf16Offset` is clamped
    /// off the split before conversion — see the clamp policy above.
    public static func position(of utf16Offset: Int, in text: String) -> Position? {
        let units = Array(text.utf16)
        guard utf16Offset >= 0, utf16Offset <= units.count else { return nil }
        let clampedOffset = clampSurrogateSplit(utf16Offset, units: units)
        let starts = lineStarts(units: units)
        var line = 0
        for i in 0..<starts.count where starts[i] <= clampedOffset {
            line = i
        }
        return Position(line: line, character: clampedOffset - starts[line])
    }

    /// Converts an LSP `LSPRange` to a whole-document UTF-16 `NSRange`. `nil` if either
    /// endpoint is out of bounds or the range is inverted (end before start). Each endpoint
    /// is clamped off a split surrogate pair independently (via `offset(of:in:)`) — an
    /// end-exclusive range stays valid, and a range that collapses to empty after clamping
    /// is returned as-is.
    public static func nsRange(of range: LSPRange, in text: String) -> NSRange? {
        guard let start = offset(of: range.start, in: text),
              let end = offset(of: range.end, in: text),
              end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }
}
