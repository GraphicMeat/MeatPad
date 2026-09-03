import XCTest

/// The card face renders Text until a row is clicked. That is what lets a drag start on the
/// title and what makes ⌘Z reach the store instead of an NSTextField — neither is visible
/// to a unit test.
final class BoardCardFaceUITests: XCTestCase {
    private var app: XCUIApplication!
    private var storageRoot: URL!
    private let boardID = UUID()
    private let columnID = UUID()
    private let secondColumnID = UUID()
    private let cardID = UUID()

    override func setUpWithError() throws {
        continueAfterFailure = false
        storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeatPadUITests-\(UUID().uuidString)", isDirectory: true)
        try seedBoard()
        app = XCUIApplication()
        app.launchArguments = [
            "-meatpad.storageRootOverride", storageRoot.path,
            "-meatpad.revealBoard", boardID.uuidString,
            "-hasSeenFirstRunIntro", "YES",
        ]
        app.launch()
        XCTAssertTrue(title.waitForExistence(timeout: 20), "board never rendered")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: storageRoot)
    }

    private var title: XCUIElement { app.descendants(matching: .any).matching(identifier: "card.title").firstMatch }
    private var notes: XCUIElement { app.descendants(matching: .any).matching(identifier: "card.notes").firstMatch }

    /// An idle row is a `Text` carrying a button trait and an editing one is a `TextField`, so
    /// the text is read from whichever of value/label the row is exposing — never by asking
    /// for an element type.
    private func faceText(_ element: XCUIElement) -> String {
        element.value as? String ?? element.label
    }

    func testClickingTheTitleEditsItAndBlurCommits() throws {
        title.click()
        XCTAssertTrue(app.textFields["card.title"].waitForExistence(timeout: 5), "the click opened no field")
        app.typeText("!")
        app.staticTexts["Todo"].firstMatch.click()   // blur

        XCTAssertTrue(poll { self.faceText(self.title) == "Alpha!" }, "the edit never landed on the face")
        XCTAssertEqual(try storedTitle(), "Alpha!")
    }

    func testDraggingTheTitleMovesTheCardToAnotherColumn() throws {
        let target = app.staticTexts["Doing"].firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        title.click(forDuration: 0.4, thenDragTo: target)

        XCTAssertTrue(waitForStoredColumn(secondColumnID), "the card never left its column")
    }

    func testCommandZRevertsANotesEdit() throws {
        notes.click()
        XCTAssertTrue(app.textFields["card.notes"].waitForExistence(timeout: 5))
        app.typeText(" typed")
        app.staticTexts["Todo"].firstMatch.click()   // blur → commit
        XCTAssertTrue(waitForStoredBody("first line\nsecond line typed"))

        app.typeKey("z", modifierFlags: .command)

        XCTAssertTrue(waitForStoredBody("first line\nsecond line"), "⌘Z did not revert the notes")
        XCTAssertEqual(faceText(notes), "first line\nsecond line")
    }

    func testUndoButtonRevertsATitleEdit() throws {
        title.click()
        app.typeText("!")
        app.staticTexts["Todo"].firstMatch.click()
        XCTAssertEqual(try storedTitle(), "Alpha!")

        let undo = app.buttons["board.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        XCTAssertTrue(undo.isEnabled)
        undo.click()

        XCTAssertTrue(poll { self.faceText(self.title) == "Alpha" }, "the face kept the undone title")
        XCTAssertEqual(try storedTitle(), "Alpha")
    }

    // MARK: - Reading the store

    private func boardJSON() throws -> [String: Any] {
        let url = storageRoot.appendingPathComponent("Boards/\(boardID.uuidString).json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    private func storedCard() throws -> [String: Any] {
        try XCTUnwrap((boardJSON()["cards"] as? [[String: Any]])?.first)
    }
    private func storedTitle() throws -> String { try XCTUnwrap(storedCard()["title"] as? String) }
    private func waitForStoredBody(_ expected: String) -> Bool { poll { (try? self.storedCard()["body"] as? String) == expected } }
    private func waitForStoredColumn(_ id: UUID) -> Bool { poll { (try? self.storedCard()["columnID"] as? String) == id.uuidString } }
    private func poll(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline { if condition() { return true }; usleep(200_000) }
        return false
    }

    // MARK: - Seeding

    private func seedBoard() throws {
        let boards = storageRoot.appendingPathComponent("Boards", isDirectory: true)
        try FileManager.default.createDirectory(at: boards, withIntermediateDirectories: true)
        let index: [String: Any] = [
            "boardOrder": [boardID.uuidString],
            "globalColumns": [
                ["id": columnID.uuidString, "name": "Todo", "isDone": false, "emoji": "📋"],
                ["id": secondColumnID.uuidString, "name": "Doing", "isDone": false, "emoji": "🚧"],
            ],
        ]
        try JSONSerialization.data(withJSONObject: index).write(to: boards.appendingPathComponent("boards.json"))
        let stamp = "2026-09-03T09:00:00Z"
        let board: [String: Any] = [
            "id": boardID.uuidString, "name": "Test Board", "extraColumns": [],
            "cards": [[
                "id": cardID.uuidString, "title": "Alpha", "body": "first line\nsecond line",
                "columnID": columnID.uuidString, "created": stamp, "modified": stamp,
            ]],
        ]
        try JSONSerialization.data(withJSONObject: board).write(to: boards.appendingPathComponent("\(boardID.uuidString).json"))
    }
}
