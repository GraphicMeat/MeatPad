import XCTest
@testable import MeatPadKit

final class ReturnKeyTests: XCTestCase {

    func testBareReturnSubmits() {
        XCTAssertFalse(ReturnKey.insertsNewline(shift: false, option: false, command: false, control: false))
    }

    func testShiftReturnInsertsNewline() {
        XCTAssertTrue(ReturnKey.insertsNewline(shift: true, option: false, command: false, control: false))
    }

    func testOptionReturnInsertsNewline() {
        XCTAssertTrue(ReturnKey.insertsNewline(shift: false, option: true, command: false, control: false))
    }

    func testShiftAndOptionTogetherInsertNewline() {
        XCTAssertTrue(ReturnKey.insertsNewline(shift: true, option: true, command: false, control: false))
    }

    /// Command and Control chords belong to whatever shortcut owns them — never to the field.
    func testCommandOrControlChordIsNotANewline() {
        XCTAssertFalse(ReturnKey.insertsNewline(shift: false, option: false, command: true, control: false))
        XCTAssertFalse(ReturnKey.insertsNewline(shift: true, option: false, command: true, control: false))
        XCTAssertFalse(ReturnKey.insertsNewline(shift: false, option: true, command: false, control: true))
    }
}
