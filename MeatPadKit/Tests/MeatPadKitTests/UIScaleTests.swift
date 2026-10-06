import XCTest
@testable import MeatPadKit

final class UIScaleTests: XCTestCase {

    func testDefaultIsActualSize() {
        XCTAssertEqual(UIScale.actualSize, 1.0)
    }

    func testZoomInStepsUpTheLadder() {
        XCTAssertEqual(UIScale.zoomedIn(from: 1.0), 1.1)
        XCTAssertEqual(UIScale.zoomedIn(from: 1.1), 1.25)
        XCTAssertEqual(UIScale.zoomedIn(from: 1.5), 1.75)
    }

    func testZoomOutStepsDownTheLadder() {
        XCTAssertEqual(UIScale.zoomedOut(from: 1.0), 0.9)
        XCTAssertEqual(UIScale.zoomedOut(from: 1.25), 1.1)
        XCTAssertEqual(UIScale.zoomedOut(from: 0.8), 0.7)
    }

    func testTheLadderStopsAtItsEnds() {
        XCTAssertEqual(UIScale.zoomedIn(from: UIScale.maximum), UIScale.maximum)
        XCTAssertEqual(UIScale.zoomedOut(from: UIScale.minimum), UIScale.minimum)
    }

    func testAnOffLadderValueSnapsToTheNextRungInTheDirectionOfTravel() {
        // 1.2 sits between 1.1 and 1.25: in goes to 1.25, out goes to 1.1 — never a no-op.
        XCTAssertEqual(UIScale.zoomedIn(from: 1.2), 1.25)
        XCTAssertEqual(UIScale.zoomedOut(from: 1.2), 1.1)
    }

    func testSanitizeRejectsNonsenseAndClamps() {
        XCTAssertEqual(UIScale.sanitized(.nan), 1.0)
        XCTAssertEqual(UIScale.sanitized(0), 1.0)
        XCTAssertEqual(UIScale.sanitized(-3), 1.0)
        XCTAssertEqual(UIScale.sanitized(50), UIScale.maximum)
        XCTAssertEqual(UIScale.sanitized(0.01), UIScale.minimum)
        XCTAssertEqual(UIScale.sanitized(1.5), 1.5)
    }

    func testLabelIsAWholePercentage() {
        XCTAssertEqual(UIScale.label(1.0), "100%")
        XCTAssertEqual(UIScale.label(1.25), "125%")
        XCTAssertEqual(UIScale.label(0.7), "70%")
    }
}
