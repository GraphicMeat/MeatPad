import Foundation

/// The one-line preview shown for a search match: indentation trimmed, and windowed so the
/// match is always visible (a long line is cut before the match and prefixed with "…").
public struct SearchSnippet: Equatable, Sendable {
    public let text: String
    /// UTF-16 range of the match inside `text`.
    public let highlight: Range<Int>

    public static let ellipsis = "…"

    /// `lead`: characters kept before the match when the line has to be cut. `maxLength`:
    /// cap on the snippet so a minified one-line file stays cheap to lay out.
    public init(match: SearchMatch, lead: Int = 20, maxLength: Int = 240) {
        let line = match.lineText as NSString
        let length = line.length
        let lower = min(max(match.rangeInLine.lowerBound, 0), length)
        let upper = min(max(match.rangeInLine.upperBound, lower), length)

        // Drop leading whitespace (never past the match start).
        var start = 0
        while start < lower, Self.isBlank(line.character(at: start)) { start += 1 }
        // Cut before the match when it sits too far in.
        var cut = false
        if lower - start > lead {
            start = line.rangeOfComposedCharacterSequence(at: lower - lead).location
            while start < lower, Self.isBlank(line.character(at: start)) { start += 1 }
            cut = true
        }
        var end = min(length, max(upper, start + maxLength))
        if end < length { end = line.rangeOfComposedCharacterSequence(at: end - 1).upperBound }
        var body = line.substring(with: NSRange(location: start, length: end - start))
        let prefix = cut ? Self.ellipsis : ""
        if end < length { body += Self.ellipsis }
        text = prefix + body
        let shift = prefix.utf16.count - start
        highlight = (lower + shift)..<(upper + shift)
    }

    private static func isBlank(_ unit: unichar) -> Bool { unit == 0x20 || unit == 0x09 }
}
