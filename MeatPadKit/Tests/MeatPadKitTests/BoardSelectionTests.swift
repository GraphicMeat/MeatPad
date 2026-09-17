import XCTest
@testable import MeatPadKit

final class BoardSelectionTests: XCTestCase {
    let ids = (0..<5).map { _ in UUID() }

    func testPlainClickReplacesSelection() {
        var s = BoardSelection()
        s.click(ids[0], .plain, order: ids); s.click(ids[2], .plain, order: ids)
        XCTAssertEqual(s.ids, [ids[2]]); XCTAssertEqual(s.anchor, ids[2])
    }
    func testToggleAddsAndRemoves() {
        var s = BoardSelection()
        s.click(ids[0], .plain, order: ids); s.click(ids[3], .toggle, order: ids)
        XCTAssertEqual(s.ids, [ids[0], ids[3]])
        s.click(ids[0], .toggle, order: ids)
        XCTAssertEqual(s.ids, [ids[3]])
    }
    func testExtendSelectsRangeFromAnchorInEitherDirection() {
        var s = BoardSelection()
        s.click(ids[3], .plain, order: ids); s.click(ids[1], .extend, order: ids)
        XCTAssertEqual(s.ids, Set(ids[1...3])); XCTAssertEqual(s.anchor, ids[3])
    }
    func testExtendWithoutUsableAnchorActsAsPlain() {
        var s = BoardSelection()
        s.click(ids[2], .extend, order: ids)
        XCTAssertEqual(s.ids, [ids[2]])
    }
    func testOrderedFollowsVisibleOrderAndPruneDropsGoneCards() {
        var s = BoardSelection()
        s.selectAll([ids[4], ids[0], ids[2]])
        XCTAssertEqual(s.ordered(ids), [ids[0], ids[2], ids[4]])
        s.prune(keeping: [ids[0], ids[4]])
        XCTAssertEqual(s.ordered(ids), [ids[0], ids[4]])
    }
    func testClearEmptiesAndDropsAnchor() {
        var s = BoardSelection(); s.select(ids[1]); s.clear()
        XCTAssertTrue(s.ids.isEmpty); XCTAssertNil(s.anchor)
    }
}
