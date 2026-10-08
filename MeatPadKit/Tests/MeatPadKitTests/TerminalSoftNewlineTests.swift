import XCTest
@testable import MeatPadKit

final class TerminalSoftNewlineTests: XCTestCase {
    private let returnKey: UInt16 = 36
    private let keypadEnter: UInt16 = 76
    private let letterA: UInt16 = 0

    /// ESC + CR: what VS Code's terminal sends for ⇧⏎, and what Claude Code reads as "newline".
    func testSequenceIsEscapeThenCarriageReturn() {
        XCTAssertEqual(TerminalSoftNewline.sequence, [0x1B, 0x0D])
    }

    func testShiftReturnIsASoftNewline() {
        XCTAssertTrue(TerminalSoftNewline.matches(keyCode: returnKey, shift: true, otherModifiers: false))
    }

    func testShiftKeypadEnterIsASoftNewline() {
        XCTAssertTrue(TerminalSoftNewline.matches(keyCode: keypadEnter, shift: true, otherModifiers: false))
    }

    /// Plain ⏎ must keep running the command.
    func testPlainReturnIsNot() {
        XCTAssertFalse(TerminalSoftNewline.matches(keyCode: returnKey, shift: false, otherModifiers: false))
    }

    /// ⌃⇧⏎, ⌥⇧⏎, ⌘⇧⏎ stay with their own handling.
    func testShiftReturnWithAnotherModifierIsNot() {
        XCTAssertFalse(TerminalSoftNewline.matches(keyCode: returnKey, shift: true, otherModifiers: true))
    }

    func testShiftOtherKeyIsNot() {
        XCTAssertFalse(TerminalSoftNewline.matches(keyCode: letterA, shift: true, otherModifiers: false))
    }
}
