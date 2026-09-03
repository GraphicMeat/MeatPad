import XCTest

/// Shift+Return and Option+Return put a line break in the board's multi-line fields; bare
/// Return still submits. Only a real key event proves this: the chord is answered by
/// AppKit's field editor, which no unit test in MeatPadKit can reach.
///
/// Every run gets its own storage root, seeded on disk before launch and thrown away after,
/// so the tests never touch the real boards and never need a click to reach one.
final class BoardNewlineUITests: XCTestCase {

    private var storageRoot = URL(fileURLWithPath: "/")
    private var boardID = UUID()

    override func setUpWithError() throws {
        continueAfterFailure = false
        storageRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MeatPadUITests-\(UUID().uuidString)", isDirectory: true)
        boardID = UUID()
        try seedBoard()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: storageRoot)
    }

    // MARK: - Add-card field

    func testShiftReturnInsertsLineBreak() {
        let app = launch()
        let field = addCardField(in: app)
        field.click()
        field.typeText("alpha")
        app.typeKey(.return, modifierFlags: .shift)
        field.typeText("beta")

        XCTAssertEqual(field.value as? String, "alpha\nbeta")
    }

    func testOptionReturnInsertsLineBreak() {
        let app = launch()
        let field = addCardField(in: app)
        field.click()
        field.typeText("alpha")
        app.typeKey(.return, modifierFlags: .option)
        field.typeText("beta")

        XCTAssertEqual(field.value as? String, "alpha\nbeta")
    }

    /// The regression that matters: a line-break chord must not cost the field its submit.
    func testBareReturnStillAddsTheCard() {
        let app = launch()
        let field = addCardField(in: app)
        field.click()
        field.typeText("gamma")
        app.typeKey(.return, modifierFlags: [])

        let title = faceTitle(in: app)
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(faceText(title), "gamma")
        XCTAssertNotEqual(field.value as? String, "gamma", "the draft should be cleared once the card exists")
    }

    /// End to end: the break is what turns one typed entry into a card with notes.
    func testLineBreakThenReturnMakesTitleAndNotes() {
        let app = launch()
        let field = addCardField(in: app)
        field.click()
        field.typeText("alpha")
        app.typeKey(.return, modifierFlags: .shift)
        field.typeText("beta")
        app.typeKey(.return, modifierFlags: [])

        let title = faceTitle(in: app)
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(faceText(title), "alpha")

        let notes = faceNotes(in: app)
        XCTAssertTrue(notes.waitForExistence(timeout: 5), "the new card has no notes row")
        XCTAssertEqual(faceText(notes), "beta")
    }

    // MARK: - Card notes

    func testShiftReturnInsertsLineBreakInCardNotes() {
        let app = launch()
        let field = addCardField(in: app)
        field.click()
        field.typeText("gamma")
        app.typeKey(.return, modifierFlags: [])

        // The notes row is a `Text` until it is clicked; the click is what puts a field there.
        let notes = faceNotes(in: app)
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        notes.click()
        let notesField = app.textFields["card.notes"].firstMatch
        XCTAssertTrue(notesField.waitForExistence(timeout: 5), "clicking the notes opened no field")
        notesField.typeText("one")
        app.typeKey(.return, modifierFlags: .shift)
        notesField.typeText("two")

        XCTAssertEqual(notesField.value as? String, "one\ntwo")
    }

    // MARK: - Harness

    /// The card face renders its rows as `Text` until they are clicked, so neither row can be
    /// asked for by element type; the text is the value on a field and on an idle row alike,
    /// bar an idle row exposed as a button, which carries it as the label.
    private func faceTitle(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "card.title").firstMatch
    }

    private func faceNotes(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "card.notes").firstMatch
    }

    private func faceText(_ element: XCUIElement) -> String {
        element.value as? String ?? element.label
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-meatpad.storageRootOverride", storageRoot.path,
            "-meatpad.revealBoard", boardID.uuidString,
            "-hasSeenFirstRunIntro", "YES",
        ]
        app.launch()
        return app
    }

    private func addCardField(in app: XCUIApplication) -> XCUIElement {
        let field = app.textFields["column.addCard"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 30), "the board's first column should offer an add-card field")
        return field
    }

    /// Writes the two files `BoardStore` reads at launch: the index, and one board.
    private func seedBoard() throws {
        let boards = storageRoot.appendingPathComponent("Boards", isDirectory: true)
        try FileManager.default.createDirectory(at: boards, withIntermediateDirectories: true)

        let columnID = UUID()
        let index = """
        {"boardOrder":["\(boardID.uuidString)"],\
        "globalColumns":[{"id":"\(columnID.uuidString)","name":"Todo","isDone":false,"emoji":"📋"}]}
        """
        let board = """
        {"id":"\(boardID.uuidString)","name":"UI Tests","extraColumns":[],"cards":[]}
        """
        try index.write(to: boards.appendingPathComponent("boards.json"), atomically: true, encoding: .utf8)
        try board.write(to: boards.appendingPathComponent("\(boardID.uuidString).json"), atomically: true, encoding: .utf8)
    }
}
