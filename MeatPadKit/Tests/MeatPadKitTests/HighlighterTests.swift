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
        XCTAssertNotNil(markdown.queries[.highlights], "markdown grammar must ship a highlights query")
        XCTAssertNotNil(markdown.queries[.injections], "markdown grammar must ship an injections query")

        let markdownInline = try XCTUnwrap(GrammarRegistry.configuration(for: "markdown_inline"))
        XCTAssertNotNil(markdownInline.queries[.highlights], "markdown_inline grammar must ship a highlights query")
        XCTAssertNotNil(markdownInline.queries[.injections], "markdown_inline grammar must ship an injections query")
    }

    func testAllWiredLanguagesLoadGrammarAndQuery() {
        // Every language in the registry must yield a working Highlighter — the
        // bundle locator fails silently (nil), so this is the only signal for a
        // broken registry entry.
        for language in Languages.all {
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

    func testMarkdownHeadingHighlighted() throws {
        let hl = try XCTUnwrap(Highlighter(languageID: "markdown"))
        let text = "# Title"   // '#'=0 ' '=1 'T'=2
        hl.setText(text)
        let all = hl.highlights(in: NSRange(location: 0, length: (text as NSString).length))
        let heading = spans(all, containing: "title", covering: 2)
        XCTAssertFalse(heading.isEmpty, "expected a heading/title span covering \"Title\"; got \(all)")
    }

    func testMarkdownInlineEmphasisViaInjection() throws {
        let hl = try XCTUnwrap(Highlighter(languageID: "markdown"))
        let text = "*em* and `code`"   // '*'=0 'e'=1 'm'=2 ... '`'=10 'c'=11
        hl.setText(text)
        let all = hl.highlights(in: NSRange(location: 0, length: (text as NSString).length))
        let emphasis = spans(all, containing: "emphasis", covering: 1)
        XCTAssertFalse(emphasis.isEmpty, "expected an emphasis span covering \"em\" (proves markdown_inline was injected); got \(all)")
        let code = spans(all, containing: "literal", covering: 11)
        XCTAssertFalse(code.isEmpty, "expected a literal/code span covering \"code\"; got \(all)")
    }

    func testMarkdownFencedSwiftInjection() throws {
        let hl = try XCTUnwrap(Highlighter(languageID: "markdown"))
        let text = "```swift\nfunc f() {}\n```"
        hl.setText(text)
        let all = hl.highlights(in: NSRange(location: 0, length: (text as NSString).length))
        let funcLocation = (text as NSString).range(of: "func").location
        let keyword = spans(all, containing: "keyword", covering: funcLocation)
        XCTAssertFalse(keyword.isEmpty, "expected a keyword span over 'func' inside the fenced swift block (proves fenced-code injection); got \(all)")
    }

    func testNoStaleInjectionSpansAfterFencedBlockRemoved() throws {
        let hl = try XCTUnwrap(Highlighter(languageID: "markdown"))
        let fenced = "```swift\nfunc f() {}\n```"
        hl.setText(fenced)
        let withFence = hl.highlights(in: NSRange(location: 0, length: (fenced as NSString).length))
        XCTAssertFalse(spans(withFence, containing: "keyword", covering: (fenced as NSString).range(of: "func").location).isEmpty,
                        "expected a keyword span over 'func' inside the fenced swift block; got \(withFence)")

        let prose = "just some plain prose, no code fence here"
        hl.setText(prose)
        let withoutFence = hl.highlights(in: NSRange(location: 0, length: (prose as NSString).length))
        XCTAssertTrue(withoutFence.filter { $0.capture.contains("keyword") }.isEmpty,
                       "expected no stale keyword spans after the fenced block was removed; got \(withoutFence)")
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
