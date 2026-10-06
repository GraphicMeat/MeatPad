import XCTest
@testable import MeatPadKit

final class TerminalPanelHeightTests: XCTestCase {

    func testInRangeValuePassesThrough() {
        XCTAssertEqual(TerminalPanelHeight.clamp(300, windowHeight: 900), 300)
    }

    func testFloorIsTheMinimum() {
        XCTAssertEqual(TerminalPanelHeight.clamp(10, windowHeight: 900), TerminalPanelHeight.minimum)
        XCTAssertEqual(TerminalPanelHeight.clamp(-50, windowHeight: 900), TerminalPanelHeight.minimum)
    }

    func testCeilingLeavesTheEditorItsReserve() {
        XCTAssertEqual(TerminalPanelHeight.clamp(5000, windowHeight: 600), 600 - TerminalPanelHeight.editorReserve)
    }

    func testTinyWindowStillYieldsAtLeastTheMinimum() {
        XCTAssertEqual(TerminalPanelHeight.clamp(200, windowHeight: 100), TerminalPanelHeight.minimum)
    }

    func testDefaultIsInsideTheRangeForANormalWindow() {
        XCTAssertEqual(TerminalPanelHeight.clamp(TerminalPanelHeight.default, windowHeight: 800), TerminalPanelHeight.default)
    }
}
