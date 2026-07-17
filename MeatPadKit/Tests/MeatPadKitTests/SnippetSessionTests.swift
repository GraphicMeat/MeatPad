import XCTest
@testable import MeatPadKit

@MainActor
final class SnippetSessionTests: XCTestCase {

    private func session(_ body: String, at offset: Int = 0) throws -> SnippetSession {
        SnippetSession(snippet: try SnippetParser.parse(body), insertionOffset: offset)
    }

    // MARK: - Rendering & initial ranges

    func testInsertTextInlinesPlaceholderDefaults() throws {
        let s = try session("func ${1:name}($2) {\n\t$0\n}")
        XCTAssertEqual(s.insertText, "func name() {\n\t\n}")
        XCTAssertTrue(s.isActive)
    }

    func testInitialCurrentStopIsFirstPositive() throws {
        let s = try session("func ${1:name}($2) {\n\t$0\n}")
        // stop 1 covers "name" at offsets 5..<9
        XCTAssertEqual(s.currentStopRanges, [5..<9])
    }

    func testAbsoluteOffsetsHonorInsertionOffset() throws {
        let s = try session("func ${1:name}($2) {\n\t$0\n}", at: 100)
        XCTAssertEqual(s.currentStopRanges, [105..<109])
    }

    // MARK: - Editing the current stop shifts downstream

    func testEditingCurrentStopShiftsDownstream() throws {
        let s = try session("func ${1:name}($2) {\n\t$0\n}")
        // replace "name" (5..<9) with "hello" — grows by 1
        let edits = s.bufferDidChange(range: 5..<9, replacement: "hello")
        XCTAssertEqual(edits, [])
        XCTAssertEqual(s.currentStopRanges, [5..<10])
        // stop 2 was at 10..<10, now 11..<11
        XCTAssertTrue(s.next())
        XCTAssertEqual(s.currentStopRanges, [11..<11])
        // $0 was at 15..<15, now 16..<16
        XCTAssertFalse(s.next())
    }

    // MARK: - Mirrors

    func testEditingPrimaryReturnsMirrorEdit() throws {
        let s = try session("${1:x} = $1")
        XCTAssertEqual(s.insertText, "x = x")
        let edits = s.bufferDidChange(range: 0..<1, replacement: "hello")
        XCTAssertEqual(edits, [MirrorEdit(range: 8..<9, replacement: "hello")])
        XCTAssertEqual(s.currentStopRanges, [0..<5, 8..<13])
    }

    func testRepeatedEditsKeepMirrorsInSync() throws {
        let s = try session("${1:x} = $1")
        _ = s.bufferDidChange(range: 0..<1, replacement: "hello") // "hello = hello"
        // now shrink primary "hello" (0..<5) to "hi"
        let edits = s.bufferDidChange(range: 0..<5, replacement: "hi")
        XCTAssertEqual(edits, [MirrorEdit(range: 5..<10, replacement: "hi")])
        XCTAssertEqual(s.currentStopRanges, [0..<2, 5..<7])
    }

    // MARK: - Navigation

    func testNextWalksInOrderAndDeactivatesOnZero() throws {
        let s = try session("func ${1:name}($2) {\n\t$0\n}")
        XCTAssertTrue(s.next())   // -> 2
        XCTAssertFalse(s.next())  // -> 0, deactivate
        XCTAssertFalse(s.isActive)
    }

    func testPreviousGoesBack() throws {
        let s = try session("func ${1:name}($2) {\n\t$0\n}")
        XCTAssertTrue(s.next())        // -> 2
        XCTAssertTrue(s.previous())    // -> 1
        XCTAssertEqual(s.currentStopRanges, [5..<9])
    }

    // MARK: - Deactivation

    func testEditOutsideSpanDeactivates() throws {
        let s = try session("func ${1:name}($2) {\n\t$0\n}")
        let edits = s.bufferDidChange(range: 200..<200, replacement: "z")
        XCTAssertEqual(edits, [])
        XCTAssertFalse(s.isActive)
    }

    func testDirectEditOfMirrorDeactivates() throws {
        let s = try session("${1:x} = $1")
        // mirror is at 4..<5; current stop is the primary
        let edits = s.bufferDidChange(range: 4..<5, replacement: "z")
        XCTAssertEqual(edits, [])
        XCTAssertFalse(s.isActive)
    }

    func testCaretMovedOutsideDeactivates() throws {
        let s = try session("func ${1:name}($2) {\n\t$0\n}")
        s.caretMoved(to: 200)
        XCTAssertFalse(s.isActive)
    }

    func testCaretMovedIntoAnotherStopJumps() throws {
        let s = try session("func ${1:name}($2) {\n\t$0\n}")
        // stop 2 is the zero-width point at offset 10
        s.caretMoved(to: 10)
        XCTAssertTrue(s.isActive)
        XCTAssertEqual(s.currentStopRanges, [10..<10])
    }

    // MARK: - Zero-width stop

    func testZeroWidthStopAcceptsInsertion() throws {
        let s = try session("func ${1:name}($2) {\n\t$0\n}")
        XCTAssertTrue(s.next()) // -> stop 2 at 10..<10
        let edits = s.bufferDidChange(range: 10..<10, replacement: "arg")
        XCTAssertEqual(edits, [])
        XCTAssertEqual(s.currentStopRanges, [10..<13])
        XCTAssertTrue(s.isActive)
    }

    // MARK: - Nesting

    func testEditingNestedStopGrowsParentRange() throws {
        let s = try session("${1:outer ${2:inner}}")
        XCTAssertEqual(s.insertText, "outer inner")
        // stop 1 spans the whole thing 0..<11
        XCTAssertEqual(s.currentStopRanges, [0..<11])
        XCTAssertTrue(s.next()) // -> stop 2 "inner" at 6..<11
        XCTAssertEqual(s.currentStopRanges, [6..<11])
        // grow "inner" -> "innermost" (+4)
        _ = s.bufferDidChange(range: 6..<11, replacement: "innermost")
        XCTAssertEqual(s.currentStopRanges, [6..<15])
        XCTAssertTrue(s.previous()) // back to stop 1
        XCTAssertEqual(s.currentStopRanges, [0..<15])
    }

    // Editing a stop nested inside a parent placeholder must also refresh any
    // MIRROR of that parent, not just the parent's own (geometrically-contained)
    // text — a stale-mirror bug previously left trailing `$1` unsynced here.
    func testEditingNestedStopRefreshesParentMirror() throws {
        let s = try session("${1:${2:a}} $1")
        XCTAssertEqual(s.insertText, "a a")
        XCTAssertTrue(s.next()) // -> stop 2 (the inner "a") at 0..<1
        XCTAssertEqual(s.currentStopRanges, [0..<1])

        let edits = s.bufferDidChange(range: 0..<1, replacement: "bb")
        XCTAssertEqual(edits, [MirrorEdit(range: 3..<4, replacement: "bb")])

        XCTAssertTrue(s.previous()) // back to stop 1 (parent + its mirror)
        XCTAssertEqual(s.currentStopRanges, [0..<2, 3..<5])
    }

    // MARK: - UTF-16 / multi-unit regressions

    func testEmojiEditInStopSyncsMirrorAcrossMultiUnitDelta() throws {
        let s = try session("${1:x} = $1")
        let edits = s.bufferDidChange(range: 0..<1, replacement: "😀")
        XCTAssertEqual(edits, [MirrorEdit(range: 5..<6, replacement: "😀")])
        XCTAssertEqual(s.currentStopRanges, [0..<2, 5..<7])
    }

    func testMidBodyZeroStopIsStillVisitedLast() throws {
        let s = try session("$0 middle ${1:a}")
        // $0 sits first in the text, but visit order is still real stops before $0.
        XCTAssertEqual(s.currentStopRanges, [8..<9])
        XCTAssertFalse(s.next())
        XCTAssertFalse(s.isActive)
        XCTAssertEqual(s.currentStopRanges, [0..<0])
    }

    func testTwoMirrorsAfterPrimaryBothSync() throws {
        let s = try session("${1:x} $1 $1")
        XCTAssertEqual(s.insertText, "x x x")
        let edits = s.bufferDidChange(range: 0..<1, replacement: "hello")
        XCTAssertEqual(edits, [
            MirrorEdit(range: 8..<9, replacement: "hello"),
            MirrorEdit(range: 6..<7, replacement: "hello"),
        ])
        XCTAssertEqual(s.currentStopRanges, [0..<5, 6..<11, 12..<17])
    }
}
