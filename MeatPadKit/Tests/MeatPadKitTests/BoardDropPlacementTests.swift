import XCTest
@testable import MeatPadKit

final class BoardDropPlacementTests: XCTestCase {

    /// Two 40pt rows with a 10pt gap: mids at 20 and 70, the gap spanning 40...50.
    private let rows = [
        BoardDropRow(id: UUID(), frame: CGRect(x: 0, y: 0, width: 200, height: 40)),
        BoardDropRow(id: UUID(), frame: CGRect(x: 0, y: 50, width: 200, height: 40)),
    ]

    // MARK: - card reorder

    func testAnEmptyColumnTakesTheCardAtZero() {
        XCTAssertEqual(BoardDropPlacement.forCard(at: 123, rows: []), .insert(0))
    }

    func testAboveTheFirstRowInsertsAtZero() {
        XCTAssertEqual(BoardDropPlacement.forCard(at: -5, rows: rows), .insert(0))
        XCTAssertEqual(BoardDropPlacement.forCard(at: 10, rows: rows), .insert(0))
    }

    func testBetweenTwoRowsInsertsBetweenThem() {
        XCTAssertEqual(BoardDropPlacement.forCard(at: 45, rows: rows), .insert(1))
    }

    func testBelowTheLastRowAppends() {
        XCTAssertEqual(BoardDropPlacement.forCard(at: 200, rows: rows), .insert(2))
    }

    /// A pointer exactly on a mid belongs below that row — the row is more than half covered.
    func testExactlyOnAMidYBoundaryLandsAfterThatRow() {
        XCTAssertEqual(BoardDropPlacement.forCard(at: 20, rows: rows), .insert(1))
        XCTAssertEqual(BoardDropPlacement.forCard(at: 70, rows: rows), .insert(2))
    }

    // MARK: - image

    func testAnImageOnBareColumnSpaceMakesANewCard() {
        XCTAssertEqual(BoardDropPlacement.forImage(at: CGPoint(x: 10, y: 10), rows: []), .newCard)
    }

    func testAnImageInsideARowAttachesToThatCard() {
        XCTAssertEqual(BoardDropPlacement.forImage(at: CGPoint(x: 100, y: 60), rows: rows), .attach(rows[1].id))
        XCTAssertEqual(BoardDropPlacement.forImage(at: CGPoint(x: 100, y: 5), rows: rows), .attach(rows[0].id))
    }

    func testAnImageInTheGapBetweenRowsMakesANewCard() {
        XCTAssertEqual(BoardDropPlacement.forImage(at: CGPoint(x: 100, y: 45), rows: rows), .newCard)
        XCTAssertEqual(BoardDropPlacement.forImage(at: CGPoint(x: 900, y: 60), rows: rows), .newCard)
    }

    // MARK: - title

    func testTheNewCardTitleIsTheFileNameStem() {
        XCTAssertEqual(BoardDropPlacement.newCardTitle(fileName: "IMG_0042.jpg", fallback: "Image"), "IMG_0042")
        XCTAssertEqual(BoardDropPlacement.newCardTitle(fileName: "  spaced out.png  ", fallback: "Image"), "spaced out")
    }

    func testABlankOrMissingFileNameFallsBack() {
        XCTAssertEqual(BoardDropPlacement.newCardTitle(fileName: nil, fallback: "Image"), "Image")
        XCTAssertEqual(BoardDropPlacement.newCardTitle(fileName: "   ", fallback: "Image"), "Image")
    }
}
