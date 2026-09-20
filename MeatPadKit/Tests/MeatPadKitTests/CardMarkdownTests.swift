import XCTest
@testable import MeatPadKit

/// `CardMarkdown` is deliberately inline-only — bold/italic/code/strikethrough/links, not
/// headings or lists — and must never lose a card's text to a parse error.
final class CardMarkdownTests: XCTestCase {

    func testPlainStripsBold() {
        XCTAssertEqual(CardMarkdown.plain("**bold**"), "bold")
    }

    func testPlainStripsLinkToItsLabel() {
        XCTAssertEqual(CardMarkdown.plain("[x](https://example.com)"), "x")
    }

    func testAttributedLinkRunCarriesTheURL() {
        let attributed = CardMarkdown.attributed("[x](https://example.com)")
        let link = attributed.runs.compactMap(\.link).first
        XCTAssertEqual(link, URL(string: "https://example.com"))
    }

    func testPlainTextRoundTripsUnchanged() {
        XCTAssertEqual(CardMarkdown.plain("hello world"), "hello world")
    }

    /// Unterminated markup must never throw the text away — the card keeps its literal source.
    func testMalformedMarkdownReturnsItsOwnText() {
        XCTAssertEqual(CardMarkdown.plain("**unterminated"), "**unterminated")
    }

    /// `.inlineOnlyPreservingWhitespace` — a card's line breaks (e.g. between title and notes)
    /// must survive the round trip, not collapse into a single line.
    func testNewlinesSurvive() {
        XCTAssertEqual(CardMarkdown.plain("line1\nline2"), "line1\nline2")
    }
}
