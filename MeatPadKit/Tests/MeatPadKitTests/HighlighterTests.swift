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
