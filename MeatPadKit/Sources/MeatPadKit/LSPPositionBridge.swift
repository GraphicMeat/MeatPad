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
public enum LSPPositionBridge {
    /// UTF-16 offset of the start of each line (index 0 is always 0). One more entry exists
    /// than there are "\n"s in `text` — the text after the final "\n" (or the whole text,
    /// if there's none) is always a line, even if empty.
    private static func lineStarts(in text: String) -> [Int] {
        var starts = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 0x0A { starts.append(offset) }
        }
        return starts
    }

    private static func lineLength(_ line: Int, starts: [Int], totalUTF16Count: Int) -> Int {
        if line + 1 < starts.count {
            return starts[line + 1] - starts[line] - 1 // exclude the trailing "\n"
        }
        return totalUTF16Count - starts[line]
    }

    /// Converts an LSP `Position` to a whole-document UTF-16 offset. `nil` if the line is
    /// out of bounds, or the character is negative or past the line's end (character may
    /// equal the line's UTF-16 length — the end-of-line position — but no more).
    public static func offset(of position: Position, in text: String) -> Int? {
        let starts = lineStarts(in: text)
        guard position.line >= 0, position.line < starts.count else { return nil }
        let length = lineLength(position.line, starts: starts, totalUTF16Count: text.utf16.count)
        guard position.character >= 0, position.character <= length else { return nil }
        return starts[position.line] + position.character
    }

    /// Converts a whole-document UTF-16 offset to an LSP `Position`. `nil` if `utf16Offset`
    /// is negative or past the end of `text`.
    public static func position(of utf16Offset: Int, in text: String) -> Position? {
        guard utf16Offset >= 0, utf16Offset <= text.utf16.count else { return nil }
        let starts = lineStarts(in: text)
        var line = 0
        for i in 0..<starts.count where starts[i] <= utf16Offset {
            line = i
        }
        return Position(line: line, character: utf16Offset - starts[line])
    }

    /// Converts an LSP `LSPRange` to a whole-document UTF-16 `NSRange`. `nil` if either
    /// endpoint is out of bounds or the range is inverted (end before start).
    public static func nsRange(of range: LSPRange, in text: String) -> NSRange? {
        guard let start = offset(of: range.start, in: text),
              let end = offset(of: range.end, in: text),
              end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }
}
