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

    /// Parses `text` as inline markdown. Never throws outward: a card must never lose its text
    /// to a parse error, so any throw here falls back to the plain, unstyled string.
    public static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    /// The same text with markup stripped — what search, the plain-text export, and anywhere
    /// else that can't render `AttributedString` should read instead of the raw source.
    public static func plain(_ text: String) -> String {
        String(attributed(text).characters)
    }
}
