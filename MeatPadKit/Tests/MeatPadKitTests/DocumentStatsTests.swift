import XCTest
@testable import MeatPadKit

final class DocumentStatsTests: XCTestCase {

    // MARK: - Lines

    func testEmptyTextIsOneLine() {
        XCTAssertEqual(DocumentStats.lineCount(of: ""), 1)
    }

    func testLineCountIsNewlinesPlusOne() {
        XCTAssertEqual(DocumentStats.lineCount(of: "a"), 1)
        XCTAssertEqual(DocumentStats.lineCount(of: "a\nb"), 2)
        XCTAssertEqual(DocumentStats.lineCount(of: "a\nb\n"), 3)
    }

    func testCarriageReturnsDoNotStartALine() {
        // Matches the old `components(separatedBy: "\n")` behaviour: CRLF is one break.
        XCTAssertEqual(DocumentStats.lineCount(of: "a\r\nb"), 2)
        XCTAssertEqual(DocumentStats.lineCount(of: "a\rb"), 1)
    }

    // MARK: - Words

    func testWordCountIgnoresLeadingTrailingAndRepeatedWhitespace() {
        XCTAssertEqual(DocumentStats.wordCount(of: ""), 0)
        XCTAssertEqual(DocumentStats.wordCount(of: "   \n\t "), 0)
        XCTAssertEqual(DocumentStats.wordCount(of: "  one   two\n\tthree  "), 3)
    }

    func testWordCountTreatsNewlinesAsSeparators() {
        XCTAssertEqual(DocumentStats.wordCount(of: "one\ntwo\r\nthree"), 3)
    }

    func testMultiByteRunsCountAsOneWord() {
        XCTAssertEqual(DocumentStats.wordCount(of: "héllo wörld"), 2)
        XCTAssertEqual(DocumentStats.wordCount(of: "👨‍👩‍👧 家族"), 2)
    }

    // MARK: - compute

    func testComputeReportsGraphemeCharacters() {
        let stats = DocumentStats.compute("héllo\n👨‍👩‍👧")
        XCTAssertEqual(stats.lines, 2)
        XCTAssertEqual(stats.words, 2)
        XCTAssertEqual(stats.characters, 7) // "héllo" + "\n" + one family grapheme
    }

    func testComputeOnEmptyTextMatchesTheEmptyPlaceholder() {
        XCTAssertEqual(DocumentStats.compute(""), .empty)
    }

    /// The whole point of the type: a bridged `NSString` must not be walked per render.
    /// This only asserts the numbers survive bridging — the perf claim is measured in the app.
    func testComputeAgreesWithTheNaiveCountsOnABridgedString() {
        let source = String(repeating: "the quick brown fox\n", count: 5_000)
        let bridged = (source as NSString) as String
        let stats = DocumentStats.compute(bridged)
        XCTAssertEqual(stats.lines, source.components(separatedBy: "\n").count)
        XCTAssertEqual(stats.words, source.split(whereSeparator: \.isWhitespace).count)
        XCTAssertEqual(stats.characters, source.count)
    }
}
