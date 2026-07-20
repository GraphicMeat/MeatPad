import XCTest
import LanguageServerProtocol
@testable import MeatPadKit

final class FindReferencesTests: XCTestCase {
    private let fileA = URL(string: "file:///a.swift")!
    private let fileB = URL(string: "file:///b.swift")!

    // MARK: - searchMatch(for:url:lines:) — line-clamp + UTF-16 range

    func testHitAtLineStart() {
        let location = Location(uri: "file:///a.swift", range: LSPRange(startPair: (0, 0), endPair: (0, 3)))
        let match = FindReferences.searchMatch(for: location, url: fileA, lines: ["foo bar"])
        XCTAssertEqual(match?.lineNumber, 1)
        XCTAssertEqual(match?.lineText, "foo bar")
        XCTAssertEqual(match?.rangeInLine, 0..<3)
    }

    func testHitAtLineEnd() {
        let line = "foo bar"
        let end = line.utf16.count
        let location = Location(uri: "file:///a.swift", range: LSPRange(startPair: (0, end - 3), endPair: (0, end)))
        let match = FindReferences.searchMatch(for: location, url: fileA, lines: [line])
        XCTAssertEqual(match?.rangeInLine, (end - 3)..<end)
    }

    func testOutOfRangeLineClampsToNil() {
        let location = Location(uri: "file:///a.swift", range: LSPRange(startPair: (5, 0), endPair: (5, 3)))
        XCTAssertNil(FindReferences.searchMatch(for: location, url: fileA, lines: ["only one line"]))
    }

    func testNegativeLineIsNil() {
        let location = Location(uri: "file:///a.swift", range: LSPRange(startPair: (-1, 0), endPair: (-1, 3)))
        XCTAssertNil(FindReferences.searchMatch(for: location, url: fileA, lines: ["line"]))
    }

    /// A multi-line range (end.line != start.line) clamps the preview highlight to the rest
    /// of the start line, rather than reading into the next line's text.
    func testMultiLineRangeClampsToStartLineEnd() {
        let line = "abc"
        let location = Location(uri: "file:///a.swift", range: LSPRange(startPair: (0, 1), endPair: (1, 0)))
        let match = FindReferences.searchMatch(for: location, url: fileA, lines: [line, "def"])
        XCTAssertEqual(match?.rangeInLine, 1..<3)
    }

    /// `character` offsets are UTF-16 code units. An emoji (surrogate pair, 2 UTF-16 units)
    /// before the hit shifts the hit's UTF-16 offset by 2, not by 1 `Character`/grapheme.
    func testUTF16OffsetWithEmojiBeforeHit() {
        let line = "😀hit"
        XCTAssertEqual(line.utf16.count, 5) // 2 (emoji) + 3 ("hit")
        let location = Location(uri: "file:///a.swift", range: LSPRange(startPair: (0, 2), endPair: (0, 5)))
        let match = FindReferences.searchMatch(for: location, url: fileA, lines: [line])
        XCTAssertEqual(match?.rangeInLine, 2..<5)
        XCTAssertEqual(match?.lineText, line)
    }

    // MARK: - group(_:) — multi-file grouping, first-seen order

    func testGroupPreservesFirstSeenFileOrderAndInterleavesMatches() {
        let matchA1 = SearchMatch(file: fileA, lineNumber: 1, lineText: "a1", rangeInLine: 0..<1)
        let matchB1 = SearchMatch(file: fileB, lineNumber: 1, lineText: "b1", rangeInLine: 0..<1)
        let matchA2 = SearchMatch(file: fileA, lineNumber: 2, lineText: "a2", rangeInLine: 0..<1)

        let groups = FindReferences.group([
            (fileA, matchA1),
            (fileB, matchB1),
            (fileA, matchA2),
        ])

        XCTAssertEqual(groups.map(\.file), [fileA, fileB])
        XCTAssertEqual(groups[0].matches, [matchA1, matchA2])
        XCTAssertEqual(groups[1].matches, [matchB1])
    }

    func testGroupEmptyIsEmpty() {
        XCTAssertEqual(FindReferences.group([]).count, 0)
    }
}
