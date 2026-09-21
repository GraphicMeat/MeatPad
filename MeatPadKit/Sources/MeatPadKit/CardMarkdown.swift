import Foundation

/// Renders a card's title/notes as INLINE markdown only — bold, italic, code, strikethrough,
/// links. Headings, lists, block quotes and the rest of full markdown are deliberately out of
/// scope: a card face is one or two lines, not a document, and a "# " a user types as a literal
/// hash should stay literal text, not jump to heading size. Foundation-only (no AppKit/SwiftUI)
/// so it stays usable from a unit test without a UI, and from anywhere else in the kit that
/// wants the same rendering (`CardTextSplit`, exports) without pulling in a view framework.
public enum CardMarkdown {
    private static let options = AttributedString.MarkdownParsingOptions(
        allowsExtendedAttributes: true,
        interpretedSyntax: .inlineOnlyPreservingWhitespace,
        failurePolicy: .returnPartiallyParsedIfPossible
    )

    /// One parse held per string. A card face asks for the same title and notes on every
    /// layout pass, and `AttributedString(markdown:)` is not cheap enough to run a boardful of
    /// them per scrolled frame. `NSCache` because it evicts itself under memory pressure and
    /// is thread-safe, which a bare dictionary behind a lock would have to be taught.
    /// `@unchecked` and genuinely safe: the box is written once in `init` and never mutated,
    /// and what it holds is a value type — a reader gets its own copy of the `AttributedString`.
    private final class Parsed: @unchecked Sendable {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    private static let cache: NSCache<NSString, Parsed> = {
        let cache = NSCache<NSString, Parsed>()
        cache.countLimit = 1000
        return cache
    }()

    /// Parses `text` as inline markdown. Never throws outward: a card must never lose its text
    /// to a parse error, so any throw here falls back to the plain, unstyled string.
    public static func attributed(_ text: String) -> AttributedString {
        let key = text as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let parsed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        cache.setObject(Parsed(parsed), forKey: key)
        return parsed
    }

    /// The same text with markup stripped — what search, the plain-text export, and anywhere
    /// else that can't render `AttributedString` should read instead of the raw source.
    public static func plain(_ text: String) -> String {
        String(attributed(text).characters)
    }
}
