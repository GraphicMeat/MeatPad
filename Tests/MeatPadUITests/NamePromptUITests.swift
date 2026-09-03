import XCTest

/// The New Board prompt used to be an NSAlert that opened with a focus ring on Cancel. The
/// sheet opens with the caret in the field and nothing else focused.
final class NamePromptUITests: XCTestCase {
    private var app: XCUIApplication!
    private var storageRoot: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeatPadUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchArguments = [
            "-meatpad.storageRootOverride", storageRoot.path,
            // "all" (not an empty string — AppModel.swift only recognizes "all" or a board
            // UUID) opens the browser straight onto the All Boards sidebar.
            "-meatpad.revealBoard", "all",
            "-hasSeenFirstRunIntro", "YES",
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: storageRoot)
    }

    func testNewBoardSheetFocusesTheFieldAndCreatesTheBoard() throws {
        let row = app.buttons["sidebar.newBoard"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no New Board row in the sidebar")
        row.click()

        let field = app.textFields["namePrompt.name"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no sheet opened")
        XCTAssertEqual(field.value(forKey: "hasKeyboardFocus") as? Bool, true, "the field did not take focus")
        XCTAssertNotEqual(app.buttons["namePrompt.cancel"].value(forKey: "hasKeyboardFocus") as? Bool, true,
                          "Cancel took focus on open — the ring is back")

        app.typeText("Launch")
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(app.staticTexts["Launch"].firstMatch.waitForExistence(timeout: 5), "the board was not created")
        XCTAssertFalse(field.exists, "the sheet stayed open")
    }
}
