import XCTest
@testable import MeatPadKit

@MainActor
final class NoteSearchTests: XCTestCase {
    private func note(_ title: String, folder: String? = nil) -> Note {
        Note(id: UUID(), languageID: nil, created: .now, modified: .now, cursor: 0, title: title, folder: folder)
    }

    func testTitleMatchesRankAboveContentMatchesPreservingInputOrder() {
        let index = NoteSearchIndex()
        let contentOnly = note("Grocery List")
        let titleMatch = note("Swift Notes")
        index.update(id: contentOnly.id, contents: "remember to buy swift bread")
        index.update(id: titleMatch.id, contents: "nothing relevant here")

        // Input order deliberately puts the content-only match first.
        let results = index.search("swift", notes: [contentOnly, titleMatch])

        XCTAssertEqual(results.map(\.noteID), [titleMatch.id, contentOnly.id])
        XCTAssertTrue(results[0].isTitleMatch)
        XCTAssertFalse(results[1].isTitleMatch)
    }

    func testContentHitProducesExcerptWithRangeInExcerptAndRangeInContents() {
        let index = NoteSearchIndex()
        let n = note("Untitled")
        // Line boundaries close enough to the hit to force snapping on both sides,
        // with unrelated filler further out that must be excluded from the excerpt.
        let junkBefore = String(repeating: "z", count: 100)   // beyond the 40-unit lookback: excluded
        let contextBefore = String(repeating: "x", count: 50) // within the lookback: included
        let junkAfter = String(repeating: "y", count: 150)    // snapped-to boundary pulls this in
        let contextAfter = String(repeating: "w", count: 100) // beyond the trailing newline: excluded
        let contents = junkBefore + "\n" + contextBefore + "NEEDLE" + junkAfter + "\n" + contextAfter
        index.update(id: n.id, contents: contents)

        let results = index.search("needle", notes: [n])
        XCTAssertEqual(results.count, 1)
        let match = results[0]
        XCTAssertFalse(match.isTitleMatch)

        let ns = contents as NSString
        let expectedContentsRange = ns.range(of: "NEEDLE")
        XCTAssertEqual(match.rangeInContents, expectedContentsRange)

        XCTAssertTrue(match.excerpt.hasPrefix("…"), "expected truncation prefix; got \(match.excerpt)")
        XCTAssertTrue(match.excerpt.hasSuffix("…"), "expected truncation suffix; got \(match.excerpt)")
        XCTAssertFalse(match.excerpt.contains("z"), "junk beyond the leading boundary must be excluded; got \(match.excerpt)")
        XCTAssertFalse(match.excerpt.contains("w"), "junk beyond the trailing boundary must be excluded; got \(match.excerpt)")
        XCTAssertTrue(match.excerpt.contains("x"), "context within the leading boundary must be kept; got \(match.excerpt)")
        XCTAssertTrue(match.excerpt.contains("y"), "context within the trailing boundary must be kept; got \(match.excerpt)")

        let rangeInExcerpt = try! XCTUnwrap(match.rangeInExcerpt)
        let excerptNS = match.excerpt as NSString
        let hitInExcerpt = excerptNS.substring(with: rangeInExcerpt)
        XCTAssertEqual(hitInExcerpt, "NEEDLE")
    }

    func testNonASCIITextBeforeHitKeepsUTF16OffsetsCorrect() {
        let index = NoteSearchIndex()
        let n = note("Untitled")
        // 🎉 is a surrogate pair (2 UTF-16 units); 世界 is 2 BMP scalars (2 UTF-16 units).
        // "🎉 世界 " = 2 + 1 + 1 + 1 + 1 = 6 UTF-16 units, then the hit.
        let text = "🎉 世界 NEEDLE rest"
        index.update(id: n.id, contents: text)

        let results = index.search("needle", notes: [n])
        XCTAssertEqual(results.count, 1)
        let match = results[0]

        let ns = text as NSString
        let expectedContentsRange = ns.range(of: "NEEDLE")
        XCTAssertEqual(expectedContentsRange.location, 6, "sanity check on the fixture's UTF-16 layout")
        XCTAssertEqual(match.rangeInContents, expectedContentsRange)

        let rangeInExcerpt = try! XCTUnwrap(match.rangeInExcerpt)
        let excerptNS = match.excerpt as NSString
        XCTAssertEqual(excerptNS.substring(with: rangeInExcerpt), "NEEDLE")
    }

    func testRemoveDropsNoteFromContentResults() {
        let index = NoteSearchIndex()
        let n = note("Untitled")
        index.update(id: n.id, contents: "has the needle in it")

        XCTAssertEqual(index.search("needle", notes: [n]).count, 1)

        index.remove(id: n.id)

        XCTAssertEqual(index.search("needle", notes: [n]).count, 0)
    }

    func testUnindexedNoteMatchesByTitleOnlyWithEmptyExcerpt() {
        let index = NoteSearchIndex()
        let n = note("Swift Notes")
        // Deliberately never call index.update(id:contents:) for this note.

        let results = index.search("swift", notes: [n])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].isTitleMatch)
        XCTAssertEqual(results[0].excerpt, "")
        XCTAssertNil(results[0].rangeInExcerpt)
        XCTAssertNil(results[0].rangeInContents)
    }

    func testEmptyQueryReturnsAllNotesInInputOrderWithNoExcerpts() {
        let index = NoteSearchIndex()
        let a = note("Alpha")
        let b = note("Beta")
        index.update(id: a.id, contents: "some content")
        index.update(id: b.id, contents: "other content")

        let results = index.search("", notes: [a, b])

        XCTAssertEqual(results.map(\.noteID), [a.id, b.id])
        XCTAssertTrue(results.allSatisfy { $0.excerpt.isEmpty && $0.rangeInExcerpt == nil && $0.rangeInContents == nil })
    }
}
