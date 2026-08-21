import Foundation

/// Whole-document line/word/character counts for the editor status bar.
///
/// These are computed once per text change, off the main actor — never inside a SwiftUI
/// `body`. A layout pass can evaluate the status bar many times per frame, and when the
/// editor's text is a lazily bridged `NSTextStorage` string every full-text walk also
/// forces a fresh native copy of the whole document. At 6 MB that pins a core and pushes
/// the process past a gigabyte.
public struct DocumentStats: Equatable, Sendable {
    public var lines: Int
    public var words: Int
    public var characters: Int

    /// What an empty document counts as, and the placeholder shown until the first
    /// background pass lands.
    public static let empty = DocumentStats(lines: 1, words: 0, characters: 0)

    public init(lines: Int, words: Int, characters: Int) {
        self.lines = lines
        self.words = words
        self.characters = characters
    }

    public static func compute(_ text: String) -> DocumentStats {
        // One native copy up front: a bridged NSString walks its UTF-8 view element by
        // element, so paying for contiguity once beats three slow passes.
        var text = text
        text.makeContiguousUTF8()
        return DocumentStats(
            lines: lineCount(of: text),
            words: wordCount(of: text),
            characters: text.count
        )
    }

    /// Newlines + 1, without materialising the lines themselves.
    public static func lineCount(of text: String) -> Int {
        var lines = 1
        for byte in text.utf8 where byte == 0x0A { lines += 1 }
        return lines
    }

    /// Whitespace-separated runs, without allocating a substring per word.
    // ponytail: ASCII whitespace only. Text split by U+00A0 or U+2028 counts as one word
    // where `split(whereSeparator: \.isWhitespace)` counted two. Widen to a scalar walk if
    // a real document ever cares — the byte scan is what keeps multi-megabyte files cheap.
    public static func wordCount(of text: String) -> Int {
        var words = 0
        var inWord = false
        for byte in text.utf8 {
            if byte == 0x20 || (byte >= 0x09 && byte <= 0x0D) {
                inWord = false
            } else if !inWord {
                inWord = true
                words += 1
            }
        }
        return words
    }
}
