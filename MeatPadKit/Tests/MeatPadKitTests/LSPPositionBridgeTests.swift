import XCTest
import LanguageServerProtocol
@testable import MeatPadKit

final class LSPPositionBridgeTests: XCTestCase {
    // MARK: - offset(of:in:) — position to UTF-16 offset

    func testOffsetAtLineStart() {
        XCTAssertEqual(LSPPositionBridge.offset(of: Position(line: 1, character: 0), in: "abc\ndef"), 4)
    }

    func testOffsetAtLineEnd() {
        // "abc" is 3 UTF-16 units; character 3 is the end-of-line position, still valid.
        XCTAssertEqual(LSPPositionBridge.offset(of: Position(line: 0, character: 3), in: "abc\ndef"), 3)
    }

    func testOffsetOfFinalPositionInDocument() {
        XCTAssertEqual(LSPPositionBridge.offset(of: Position(line: 1, character: 3), in: "abc\ndef"), 7)
        XCTAssertEqual(7, "abc\ndef".utf16.count)
    }

    func testOffsetOutOfBoundsLineIsNil() {
        XCTAssertNil(LSPPositionBridge.offset(of: Position(line: 2, character: 0), in: "abc\ndef"))
        XCTAssertNil(LSPPositionBridge.offset(of: Position(line: -1, character: 0), in: "abc\ndef"))
    }

    func testOffsetOutOfBoundsCharacterIsNil() {
        // Line 0 ("abc") only has 3 units; character 4 overruns it.
        XCTAssertNil(LSPPositionBridge.offset(of: Position(line: 0, character: 4), in: "abc\ndef"))
        XCTAssertNil(LSPPositionBridge.offset(of: Position(line: 0, character: -1), in: "abc\ndef"))
    }

    func testOffsetInEmptyText() {
        XCTAssertEqual(LSPPositionBridge.offset(of: Position(line: 0, character: 0), in: ""), 0)
        XCTAssertNil(LSPPositionBridge.offset(of: Position(line: 0, character: 1), in: ""))
        XCTAssertNil(LSPPositionBridge.offset(of: Position(line: 1, character: 0), in: ""))
    }

    func testOffsetWithMultiLineEmojiAndCJK() {
        // Line 0: "😀" (surrogate pair, 2 UTF-16 units). Line 1: "中文" (2 units, both BMP).
        let text = "😀\n中文"
        XCTAssertEqual(LSPPositionBridge.offset(of: Position(line: 0, character: 0), in: text), 0)
        XCTAssertEqual(LSPPositionBridge.offset(of: Position(line: 0, character: 2), in: text), 2) // end of emoji
        XCTAssertEqual(LSPPositionBridge.offset(of: Position(line: 1, character: 0), in: text), 3) // start of 中
        XCTAssertEqual(LSPPositionBridge.offset(of: Position(line: 1, character: 1), in: text), 4) // between 中 and 文
        XCTAssertEqual(LSPPositionBridge.offset(of: Position(line: 1, character: 2), in: text), 5) // end of line
        XCTAssertNil(LSPPositionBridge.offset(of: Position(line: 1, character: 3), in: text))
    }

    // MARK: - Surrogate-pair clamping — mid-pair offsets clamp to the pair's start

    func testOffsetMidSurrogatePairClampsToPairStart() {
        // "😀x": character 1 lands between the emoji's two UTF-16 units; clamp to 0.
        XCTAssertEqual(LSPPositionBridge.offset(of: Position(line: 0, character: 1), in: "😀x"), 0)
        // character 0 (pair start) and character 2 (past the pair) are untouched.
        XCTAssertEqual(LSPPositionBridge.offset(of: Position(line: 0, character: 0), in: "😀x"), 0)
        XCTAssertEqual(LSPPositionBridge.offset(of: Position(line: 0, character: 2), in: "😀x"), 2)
    }

    func testPositionMidSurrogatePairClampsToPairStart() {
        // Offset 1 is mid-pair in "😀x"; clamp lands back at the pair's start, (0, 0).
        XCTAssertEqual(LSPPositionBridge.position(of: 1, in: "😀x"), Position(line: 0, character: 0))
    }

    func testNSRangeStraddlingSurrogatePairsClampsBothEnds() {
        // "😀😀": 4 UTF-16 units (pair, pair). character 1 and 3 each split a pair.
        let range = LSPRange(start: Position(line: 0, character: 1), end: Position(line: 0, character: 3))
        // start clamps 1 -> 0 (first pair's start); end clamps 3 -> 2 (second pair's start).
        XCTAssertEqual(LSPPositionBridge.nsRange(of: range, in: "😀😀"), NSRange(location: 0, length: 2))
    }

    // MARK: - CRLF handling — "\n" is the only line separator

    func testCRLFTreatsCarriageReturnAsOrdinaryUnitOnThePrecedingLine() {
        let text = "a\r\nb" // line 0 = "a\r" (2 units), line 1 = "b" (1 unit)
        XCTAssertEqual(LSPPositionBridge.offset(of: Position(line: 0, character: 0), in: text), 0)
        XCTAssertEqual(LSPPositionBridge.offset(of: Position(line: 0, character: 2), in: text), 2) // after "a\r"
        XCTAssertNil(LSPPositionBridge.offset(of: Position(line: 0, character: 3), in: text)) // overruns line 0
        XCTAssertEqual(LSPPositionBridge.offset(of: Position(line: 1, character: 0), in: text), 3) // start of "b"
        XCTAssertEqual(LSPPositionBridge.offset(of: Position(line: 1, character: 1), in: text), 4) // end of doc
        XCTAssertNil(LSPPositionBridge.offset(of: Position(line: 2, character: 0), in: text)) // only 2 lines
    }

    // MARK: - position(of:in:) — UTF-16 offset to position

    func testPositionAtStart() {
        let pos = LSPPositionBridge.position(of: 0, in: "abc\ndef")
        XCTAssertEqual(pos, Position(line: 0, character: 0))
    }

    func testPositionAtLineBoundary() {
        // Offset 4 is right after the "\n", i.e. the start of line 1.
        let pos = LSPPositionBridge.position(of: 4, in: "abc\ndef")
        XCTAssertEqual(pos, Position(line: 1, character: 0))
    }

    func testPositionOfFinalOffset() {
        let text = "abc\ndef"
        let pos = LSPPositionBridge.position(of: text.utf16.count, in: text)
        XCTAssertEqual(pos, Position(line: 1, character: 3))
    }

    func testPositionOutOfBoundsOffsetIsNil() {
        let text = "abc\ndef"
        XCTAssertNil(LSPPositionBridge.position(of: -1, in: text))
        XCTAssertNil(LSPPositionBridge.position(of: text.utf16.count + 1, in: text))
    }

    func testPositionInEmptyText() {
        XCTAssertEqual(LSPPositionBridge.position(of: 0, in: ""), Position(line: 0, character: 0))
        XCTAssertNil(LSPPositionBridge.position(of: 1, in: ""))
    }

    func testPositionRoundTripsWithOffsetForEmojiAndCJK() {
        let text = "😀\n中文"
        let units = Array(text.utf16)
        for offset in 0...text.utf16.count {
            guard let pos = LSPPositionBridge.position(of: offset, in: text) else {
                XCTFail("expected a position for offset \(offset)")
                continue
            }
            // Every offset round-trips exactly, except one that splits the emoji's surrogate
            // pair (offset 1): that clamps back to the pair's start (offset 0) on the way in.
            let isMidPair = offset > 0 && offset < units.count
                && (0xDC00...0xDFFF).contains(units[offset])
                && (0xD800...0xDBFF).contains(units[offset - 1])
            XCTAssertEqual(LSPPositionBridge.offset(of: pos, in: text), isMidPair ? offset - 1 : offset)
        }
    }

    // MARK: - nsRange(of:in:)

    func testNSRangeOfSingleLineRange() {
        let range = LSPRange(start: Position(line: 0, character: 1), end: Position(line: 0, character: 3))
        XCTAssertEqual(LSPPositionBridge.nsRange(of: range, in: "abcdef"), NSRange(location: 1, length: 2))
    }

    func testNSRangeSpanningLines() {
        let range = LSPRange(start: Position(line: 0, character: 1), end: Position(line: 1, character: 2))
        XCTAssertEqual(LSPPositionBridge.nsRange(of: range, in: "abc\ndef"), NSRange(location: 1, length: 5))
    }

    func testNSRangeNilWhenEndPrecedesStart() {
        let range = LSPRange(start: Position(line: 0, character: 3), end: Position(line: 0, character: 1))
        XCTAssertNil(LSPPositionBridge.nsRange(of: range, in: "abcdef"))
    }

    func testNSRangeNilWhenEndpointOutOfBounds() {
        let range = LSPRange(start: Position(line: 0, character: 0), end: Position(line: 5, character: 0))
        XCTAssertNil(LSPPositionBridge.nsRange(of: range, in: "abcdef"))
    }

    func testNSRangeInEmptyText() {
        let range = LSPRange(start: Position(line: 0, character: 0), end: Position(line: 0, character: 0))
        XCTAssertEqual(LSPPositionBridge.nsRange(of: range, in: ""), NSRange(location: 0, length: 0))
    }
}
