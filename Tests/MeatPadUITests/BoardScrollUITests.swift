import XCTest

/// A column of cards scrolls on its own, and the card being made or typed into must stay in
/// view. Both are layout-after-update behaviour — a `scrollTo` run too early, a caret below the
/// column's edge — that only exists once AppKit has laid the column out.
///
/// Seeded like `BoardNewlineUITests`: a throwaway storage root launched straight onto the
/// board. The column holds far more cards than any window is tall, so the add-card field's
/// new card starts below the fold.
final class BoardScrollUITests: XCTestCase {

    private var app: XCUIApplication!
    private var storageRoot = URL(fileURLWithPath: "/")
    private var boardID = UUID()
    private var columnID = UUID()

    override func setUpWithError() throws {
        continueAfterFailure = false
        storageRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MeatPadUITests-\(UUID().uuidString)", isDirectory: true)
        boardID = UUID()
        columnID = UUID()
        try seedBoard(cards: 30)

        app = XCUIApplication()
        app.launchArguments = [
            "-meatpad.storageRootOverride", storageRoot.path,
            "-meatpad.revealBoard", boardID.uuidString,
            "-hasSeenFirstRunIntro", "YES",
            // Pinned: a remembered density would change how tall the seeded cards are.
            "-board.cardDisplay", "full",
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: storageRoot)
    }

    // MARK: - Tests

    /// The new card lands at the bottom of a column that is mostly off-screen; adding it has
    /// to bring it into view rather than leave the user looking at the top of the column.
    func testANewCardScrollsIntoView() {
        addCard(titled: "Fresh card")

        let card = faceTitle("Fresh card")
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the new card never appeared")
        XCTAssertTrue(poll { card.isHittable }, "the new card was added below the fold and the column did not scroll to it")
    }

    /// Typing past the bottom of the column: every line break grows the notes field, and the
    /// column has to follow the caret down instead of leaving it off-screen.
    func testTypingLongNotesKeepsTheCaretLineInView() {
        addCard(titled: "Fresh card")
        let card = faceTitle("Fresh card")
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(poll { card.isHittable })

        // The new card is the last in the column, so its notes row is the last one there is.
        let notes = app.descendants(matching: .any).matching(identifier: "card.notes").allElementsBoundByIndex.last
        XCTAssertNotNil(notes)
        notes?.click()
        let field = app.textFields["card.notes"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "clicking the notes opened no field")
        XCTAssertTrue(poll { (field.value(forKey: "hasKeyboardFocus") as? Bool) == true }, "the notes field never took focus")

        // `app.typeText`, not the field's: the field's would re-click its middle as it grows.
        for line in 1...15 {
            app.typeText("line \(line)")
            app.typeKey(.return, modifierFlags: .shift)
        }
        app.typeText("last line")

        let window = app.windows.firstMatch
        // The end of the notes — where the caret is — must sit inside the window, not below it.
        XCTAssertTrue(
            poll { field.frame.maxY <= window.frame.maxY + 1 && field.frame.maxY > window.frame.minY },
            "the notes grew past the bottom of the window and the column did not follow (field \(field.frame), window \(window.frame))"
        )
    }

    // MARK: - Harness

    private func addCard(titled title: String) {
        let field = app.textFields["column.addCard"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 30), "the board never offered an add-card field")
        field.click()
        field.typeText(title)
        app.typeKey(.return, modifierFlags: [])
    }

    /// The face is a `Text` until clicked, so the title is asked for by identifier and read
    /// from its value (the label on an element that carries no value).
    private func faceTitle(_ text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'card.title' AND (value == %@ OR label == %@)", text, text))
            .firstMatch
    }

    private func poll(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(200_000)
        }
        return false
    }

    /// The same files `BoardStore` writes: an index plus one board file, `cards` cards in it.
    private func seedBoard(cards count: Int) throws {
        let boards = storageRoot.appendingPathComponent("Boards", isDirectory: true)
        try FileManager.default.createDirectory(at: boards, withIntermediateDirectories: true)
        let index: [String: Any] = ["boardOrder": [boardID.uuidString]]
        try JSONSerialization.data(withJSONObject: index).write(to: boards.appendingPathComponent("boards.json"))

        let stamp = "2026-09-20T09:00:00Z"
        let cards: [[String: Any]] = (1...count).map { number in
            ["id": UUID().uuidString, "title": "Seed card \(number)", "body": "Notes for seed card \(number)",
             "columnID": columnID.uuidString, "created": stamp, "modified": stamp]
        }
        let board: [String: Any] = [
            "id": boardID.uuidString, "name": "Scroll Board",
            "extraColumns": [["id": columnID.uuidString, "name": "Todo", "isDone": false, "emoji": "📋"]],
            "cards": cards,
        ]
        try JSONSerialization.data(withJSONObject: board)
            .write(to: boards.appendingPathComponent("\(boardID.uuidString).json"))
    }
}
