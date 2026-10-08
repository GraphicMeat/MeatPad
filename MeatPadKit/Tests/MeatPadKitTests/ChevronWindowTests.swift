import XCTest
@testable import MeatPadKit

final class ChevronWindowTests: XCTestCase {
    private let heads = [0, 100, 200, 300, 400, 500]

    func testSelectsHeadsInsideViewportPlusMargin() {
        XCTAssertEqual(ChevronWindow.indices(headOffsets: heads, viewport: 200..<300, margin: 0), 2..<4)
        XCTAssertEqual(ChevronWindow.indices(headOffsets: heads, viewport: 200..<300, margin: 100), 1..<5)
    }

    func testClampsAtDocumentEdges() {
        XCTAssertEqual(ChevronWindow.indices(headOffsets: heads, viewport: 0..<50, margin: 1_000), 0..<6)
    }

    func testViewportBeyondLastHeadIsEmpty() {
        XCTAssertTrue(ChevronWindow.indices(headOffsets: heads, viewport: 900..<1_000, margin: 0).isEmpty)
    }

    func testNoHeads() {
        XCTAssertTrue(ChevronWindow.indices(headOffsets: [], viewport: 0..<10, margin: 5).isEmpty)
    }
}
