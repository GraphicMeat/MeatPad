import XCTest
@testable import MeatPadKit

final class HighlighterTests: XCTestCase {
    /// Returns spans whose capture contains `needle` and whose range covers `location`.
    private func spans(_ hl: [HighlightSpan], containing needle: String, covering location: Int) -> [HighlightSpan] {
        hl.filter { $0.capture.contains(needle) && NSLocationInRange(location, $0.range) }
    }

    func testUnknownLanguageReturnsNil() {
        XCTAssertNil(Highlighter(languageID: "nope"))
    }

    func testKnownLanguageIsNonNil() {
        XCTAssertNotNil(Highlighter(languageID: "json"))
    }

    func testJSONHighlightsPropertyAndNumber() throws {
        let hl = try XCTUnwrap(Highlighter(languageID: "json"))
        let text = #"{"a": 1}"#   // '{'=0 '"'=1 'a'=2 '"'=3 ':'=4 ' '=5 '1'=6 '}'=7
        hl.setText(text)
        let spans = hl.highlights(in: NSRange(location: 0, length: (text as NSString).length))

        let key = spans.filter {
            ($0.capture.contains("string") || $0.capture.contains("property")) && NSLocationInRange(2, $0.range)
        }
        XCTAssertFalse(key.isEmpty, "expected a string/property span covering the key \"a\"; got \(spans)")

        let number = self.spans(spans, containing: "number", covering: 6)
        XCTAssertFalse(number.isEmpty, "expected a number span covering '1'; got \(spans)")
    }

    func testPythonKeyword() throws {
        let hl = try XCTUnwrap(Highlighter(languageID: "python"))
        let text = "def foo():"   // 'def' at 0..2
        hl.setText(text)
        let spans = hl.highlights(in: NSRange(location: 0, length: (text as NSString).length))
        let keyword = self.spans(spans, containing: "keyword", covering: 0)
        XCTAssertFalse(keyword.isEmpty, "expected a keyword span covering 'def'; got \(spans)")
    }

    func testSwiftKeyword() throws {
        let hl = try XCTUnwrap(Highlighter(languageID: "swift"))
        let text = "func f() {}"   // 'func' at 0..3
        hl.setText(text)
        let spans = hl.highlights(in: NSRange(location: 0, length: (text as NSString).length))
        let keyword = self.spans(spans, containing: "keyword", covering: 0)
        XCTAssertFalse(keyword.isEmpty, "expected a keyword span covering 'func'; got \(spans)")
    }

    func testMarkdownGrammarsAreRegistered() throws {
        // Markdown isn't Highlighter-wired yet (next task makes Highlighter
        // injection-aware), but the registry entries must exist so that task
        // can build on them.
        let markdown = try XCTUnwrap(GrammarRegistry.configuration(for: "markdown"))
        XCTAssertNotNil(markdown.queries[.injections], "markdown grammar must ship an injections query")
        XCTAssertNotNil(GrammarRegistry.configuration(for: "markdown_inline"))
    }

    func testAllWiredLanguagesLoadGrammarAndQuery() {
        // Every language in the registry except markdown (dropped for P1) must
        // yield a working Highlighter — the bundle locator fails silently (nil),
        // so this is the only signal for a broken registry entry.
        for language in Languages.all where language.id != "markdown" {
            XCTAssertNotNil(Highlighter(languageID: language.id), "grammar failed to load for \(language.id)")
        }
    }

    func testNonASCIITextYieldsCorrectUTF16Offsets() throws {
        let hl = try XCTUnwrap(Highlighter(languageID: "python"))
        let text = "s = \"🎉\"\ndef f(): pass"
        // UTF-16: s=0 ' '=1 ==2 ' '=3 "=4 🎉=5,6 "=7 \n=8 def=9..11
        hl.setText(text)
        let all = hl.highlights(in: NSRange(location: 0, length: (text as NSString).length))
        XCTAssertFalse(spans(all, containing: "string", covering: 5).isEmpty, "expected string span over emoji; got \(all)")
        let keyword = spans(all, containing: "keyword", covering: 9)
        XCTAssertFalse(keyword.isEmpty, "expected keyword span at UTF-16 offset 9 ('def'); got \(all)")
        XCTAssertTrue(keyword.contains { $0.range.location == 9 && $0.range.length == 3 },
                      "keyword span should be exactly {9,3} in UTF-16; got \(keyword)")
    }

    func testCaptureNamesHaveNoLeadingAt() throws {
        let hl = try XCTUnwrap(Highlighter(languageID: "json"))
        hl.setText(#"{"a": 1}"#)
        let spans = hl.highlights(in: NSRange(location: 0, length: 8))
        XCTAssertFalse(spans.isEmpty)
        for span in spans {
            XCTAssertFalse(span.capture.hasPrefix("@"), "capture should not keep leading @: \(span.capture)")
        }
    }
}
