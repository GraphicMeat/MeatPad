import XCTest
@testable import MeatPadKit

final class WordCompleterTests: XCTestCase {

    // MARK: - Basic candidate collection & ranking

    func testReturnsMatchingWordsNearestToCaretFirst() {
        let text = "note noteStore normal "
        let caretOffset = text.utf16.count // end of buffer, right after trailing space
        let result = WordCompleter.complete(prefix: "no", in: text, caretOffset: caretOffset)
        XCTAssertEqual(result, ["normal", "noteStore", "note"])
    }

    // MARK: - Word at caret excluded

    func testWordBeingTypedAtCaretIsExcluded() {
        // Caret sits inside the first "note" (between 'o' and 't'); that
        // occurrence must not count, but the second, untouched occurrence must.
        let text = "note nx note"
        let caretOffset = 2
        let result = WordCompleter.complete(prefix: "no", in: text, caretOffset: caretOffset)
        XCTAssertEqual(result, ["note"])
    }

    // MARK: - Candidate equal to prefix excluded

    func testCandidateEqualToPrefixIsExcluded() {
        let text = "no notable "
        let caretOffset = text.utf16.count // trailing space keeps caret off both words
        let result = WordCompleter.complete(prefix: "no", in: text, caretOffset: caretOffset)
        XCTAssertEqual(result, ["notable"])
    }

    // MARK: - Case-insensitive match, exact-case preferred at equal distance

    func testExactCaseOutranksCaseFoldedAtEqualDistance() {
        let left = "Note"
        let gap = " zzzz " // 6 chars: caret lands exactly midway between the two starts
        let right = "note"
        let text = left + gap + right
        let caretOffset = (left.utf16.count + (left + gap).utf16.count) / 2
        let result = WordCompleter.complete(prefix: "no", in: text, caretOffset: caretOffset)
        XCTAssertEqual(result, ["note", "Note"], "equal distance: exact-case match should rank first")
    }

    // MARK: - Dedupe keeps nearest occurrence

    func testDedupeKeepsNearestOccurrenceForRanking() {
        let a = "note "
        let filler = String(repeating: "z", count: 20) + " "
        let b = "normal "
        let c = "note"
        let tail = " tail"
        let text = a + filler + b + c + tail
        // One char past the second "note" — close to it, far from the first.
        let caretOffset = (a + filler + b + c).utf16.count + 1
        let result = WordCompleter.complete(prefix: "no", in: text, caretOffset: caretOffset)
        XCTAssertEqual(result, ["note", "normal"], "nearest occurrence of the duplicated word should win the ranking")
    }

    // MARK: - Limit

    func testLimitIsRespected() {
        let words = (0..<30).map { "notion\($0)" }
        let text = words.joined(separator: " ")
        let result = WordCompleter.complete(prefix: "no", in: text, caretOffset: 0, limit: 5)
        XCTAssertEqual(result.count, 5)
    }

    // MARK: - Empty prefix

    func testEmptyPrefixReturnsEmpty() {
        let result = WordCompleter.complete(prefix: "", in: "note note note", caretOffset: 0)
        XCTAssertEqual(result, [])
    }

    // MARK: - Underscore/digit word chars

    func testUnderscoreAndDigitWordCharsRespected() {
        let text = "_foo1 _foo2 bar"
        let caretOffset = text.utf16.count
        let result = WordCompleter.complete(prefix: "_f", in: text, caretOffset: caretOffset)
        XCTAssertEqual(result, ["_foo2", "_foo1"])
    }

    func testLeadingDigitDoesNotStartAWord() {
        // "9note" is not itself a word (digits can't start one); the scan
        // should still recover "note" starting right after the digit.
        let text = "9note"
        let result = WordCompleter.complete(prefix: "no", in: text, caretOffset: 100)
        XCTAssertEqual(result, ["note"])
    }

    // MARK: - No match / no words

    func testNoMatchingWordsReturnsEmpty() {
        let result = WordCompleter.complete(prefix: "zz", in: "note noteStore normal", caretOffset: 0)
        XCTAssertEqual(result, [])
    }

    // MARK: - Performance sanity (single linear scan, no per-call regex)

    func testLargeDocumentIsFast() {
        let words = (0..<20_000).map { "notionEntry\($0)" }
        let text = words.joined(separator: " ")
        let start = Date()
        let result = WordCompleter.complete(prefix: "not", in: text, caretOffset: text.utf16.count, limit: 20)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.5, "20k-word scan took \(elapsed)s, expected well under 0.5s")
        XCTAssertEqual(result.count, 20)
    }
}
