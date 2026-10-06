import XCTest
@testable import MeatPadKit

/// SwiftTerm 1.20.0 hands the raw `waitpid` status to its delegate; the panel shows a real exit code.
final class TerminalExitStatusTests: XCTestCase {

    func testCleanExitIsZero() {
        XCTAssertEqual(TerminalExitStatus.exitCode(fromWaitStatus: 0), 0)
    }

    func testExitCodeLivesInTheHighByte() {
        XCTAssertEqual(TerminalExitStatus.exitCode(fromWaitStatus: 3 << 8), 3)
        XCTAssertEqual(TerminalExitStatus.exitCode(fromWaitStatus: 255 << 8), 255)
    }

    func testSignalDeathIsNegativeSignalNumber() {
        XCTAssertEqual(TerminalExitStatus.exitCode(fromWaitStatus: 15), -15)   // SIGTERM
        XCTAssertEqual(TerminalExitStatus.exitCode(fromWaitStatus: 9), -9)     // SIGKILL
    }

    func testUnknownStatusIsMinusOne() {
        XCTAssertEqual(TerminalExitStatus.exitCode(fromWaitStatus: nil), -1)
    }
}
