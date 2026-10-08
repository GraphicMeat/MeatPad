import XCTest
@testable import MeatPadKit

final class SearchSnippetTests: XCTestCase {
    private func match(_ line: String, _ range: Range<Int>) -> SearchMatch {
        SearchMatch(file: URL(string: "file:///a.md")!, lineNumber: 1, lineText: line, rangeInLine: range)
    }

    private func highlighted(_ s: SearchSnippet) -> String {
        (s.text as NSString).substring(with: NSRange(location: s.highlight.lowerBound, length: s.highlight.count))
    }

    func testShortLineKeptWhole() {
        let s = SearchSnippet(match: match("# bede.sd app", 2..<6))
        XCTAssertEqual(s.text, "# bede.sd app")
        XCTAssertEqual(highlighted(s), "bede")
    }

    func testIndentationTrimmed() {
        let s = SearchSnippet(match: match("      let bede = 1", 10..<14))
        XCTAssertEqual(s.text, "let bede = 1")
        XCTAssertEqual(highlighted(s), "bede")
    }

    func testLateMatchIsWindowedWithEllipsis() {
        let line = String(repeating: "x", count: 80) + " bede tail"
        let s = SearchSnippet(match: match(line, 81..<85), lead: 10)
        XCTAssertTrue(s.text.hasPrefix("…"))
        XCTAssertEqual(highlighted(s), "bede")
        XCTAssertTrue(s.text.hasSuffix("bede tail"))
        XCTAssertLessThan(s.highlight.lowerBound, 14)
    }

    func testLongTailTruncatedMatchStillVisible() {
        let line = "bede " + String(repeating: "y", count: 500)
        let s = SearchSnippet(match: match(line, 0..<4), maxLength: 50)
        XCTAssertTrue(s.text.hasSuffix("…"))
        XCTAssertLessThanOrEqual(s.text.utf16.count, 52)
        XCTAssertEqual(highlighted(s), "bede")
    }

    func testEmojiBeforeMatchDoesNotSplitSurrogate() {
        let line = String(repeating: "😀", count: 30) + "bede"
        let lower = line.utf16.count - 4
        let s = SearchSnippet(match: match(line, lower..<(lower + 4)), lead: 5)
        XCTAssertEqual(highlighted(s), "bede")
        XCTAssertFalse(s.text.unicodeScalars.contains("\u{FFFD}"))
    }

    func testOutOfBoundsRangeClamped() {
        let s = SearchSnippet(match: match("abc", 5..<9))
        XCTAssertEqual(s.text, "abc")
        XCTAssertEqual(s.highlight, 3..<3)
    }
}
