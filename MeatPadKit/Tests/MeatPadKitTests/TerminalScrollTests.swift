import XCTest
@testable import MeatPadKit

final class TerminalScrollTests: XCTestCase {

    /// A trackpad reports many sub-line deltas; none may be dropped or rounded up to a line.
    func testSmallDeltasAccumulateIntoWholeLines() {
        var scroll = TerminalScrollAccumulator()
        XCTAssertEqual(scroll.lines(delta: 0.4, unit: 1), 0)
        XCTAssertEqual(scroll.lines(delta: 0.4, unit: 1), 0)
        XCTAssertEqual(scroll.lines(delta: 0.4, unit: 1), 1)
        XCTAssertEqual(scroll.lines(delta: 0.4, unit: 1), 0)
    }

    func testPixelDeltasAreDividedByTheLineHeight() {
        var scroll = TerminalScrollAccumulator()
        XCTAssertEqual(scroll.lines(delta: 32, unit: 16), 2)
        XCTAssertEqual(scroll.lines(delta: 8, unit: 16), 0)
        XCTAssertEqual(scroll.lines(delta: 8, unit: 16), 1)
    }

    func testNegativeDeltasScrollTheOtherWay() {
        var scroll = TerminalScrollAccumulator()
        XCTAssertEqual(scroll.lines(delta: -2.5, unit: 1), -2)
        XCTAssertEqual(scroll.lines(delta: -0.5, unit: 1), -1)
    }

    func testTotalLinesNeverExceedTheTotalDistance() {
        var scroll = TerminalScrollAccumulator()
        let total = (0..<100).reduce(0) { sum, _ in sum + scroll.lines(delta: 0.25, unit: 1) }
        XCTAssertEqual(total, 25)
    }

    func testResetDropsTheRemainder() {
        var scroll = TerminalScrollAccumulator()
        _ = scroll.lines(delta: 0.9, unit: 1)
        scroll.reset()
        XCTAssertEqual(scroll.lines(delta: 0.2, unit: 1), 0)
    }

    func testNonPositiveUnitScrollsNothing() {
        var scroll = TerminalScrollAccumulator()
        XCTAssertEqual(scroll.lines(delta: 50, unit: 0), 0)
        XCTAssertEqual(scroll.lines(delta: 50, unit: -3), 0)
    }
}
