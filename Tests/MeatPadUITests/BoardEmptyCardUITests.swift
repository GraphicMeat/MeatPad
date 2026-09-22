import XCTest

/// The column's `+` makes a card out of nothing, and an untitled, noteless card offers to
/// fill itself from the clipboard. Both are chrome on the card face — a unit test can prove
/// the store takes a blank card, only this can prove the buttons exist and are hittable.
final class BoardEmptyCardUITests: XCTestCase {
    private var app: XCUIApplication!
    private var storageRoot: URL!
    private let boardID = UUID()
    private let columnID = UUID()

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
        XCTAssertTrue(app.staticTexts["Todo"].firstMatch.waitForExistence(timeout: 20), "board never rendered")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: storageRoot)
    }

    private var plus: XCUIElement { app.buttons["column.addCard.plus"].firstMatch }
    private var title: XCUIElement { app.descendants(matching: .any).matching(identifier: "card.title").firstMatch }

    func testThePlusButtonAddsAnEmptyCard() throws {
        XCTAssertTrue(plus.waitForExistence(timeout: 5), "no + next to the add-card field")
        plus.click()

        XCTAssertTrue(poll { (try? self.storedCards())?.count == 1 }, "the + stored no card")
        XCTAssertEqual(try storedCards().first?["title"] as? String, "")
        XCTAssertTrue(title.waitForExistence(timeout: 5), "the new card never drew a title row")
    }

    /// The + keeps its old job when there is text to commit — it must not drop what was typed
    /// and add a blank card next to it instead.
    func testThePlusButtonStillCommitsTypedText() throws {
        let field = app.textFields["column.addCard"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        app.typeText("Typed")
        plus.click()

        XCTAssertTrue(poll { (try? self.storedCards())?.count == 1 }, "the + stored no card")
        XCTAssertEqual(try storedCards().first?["title"] as? String, "Typed")
    }

    func testPastingFillsAnEmptyCardFromTheClipboard() throws {
        plus.click()
        let paste = app.buttons["card.paste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "the empty card offers no paste button")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("Pasted title\nthe rest of it", forType: .string)
        paste.click()

        XCTAssertTrue(poll { (try? self.storedCards().first?["title"] as? String) == "Pasted title" },
                      "the paste never landed: \(String(describing: try? storedCards().first))")
        XCTAssertEqual(try storedCards().first?["body"] as? String, "the rest of it")
        // Nothing left to fill: the button goes away once the card carries text.
        XCTAssertTrue(poll { !paste.exists }, "the paste button outlived the empty card")
    }

    /// An empty clipboard must not wipe the button's reason to exist, nor the card.
    func testPastingNothingLeavesTheCardAlone() throws {
        plus.click()
        let paste = app.buttons["card.paste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        NSPasteboard.general.clearContents()
        paste.click()

        XCTAssertEqual(try storedCards().count, 1)
        XCTAssertEqual(try storedCards().first?["title"] as? String, "")
        XCTAssertTrue(paste.exists)
    }

    // MARK: - Harness

    private func seedBoard() throws {
        let boards = storageRoot.appendingPathComponent("Boards", isDirectory: true)
        try FileManager.default.createDirectory(at: boards, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["boardOrder": [boardID.uuidString]])
            .write(to: boards.appendingPathComponent("boards.json"))
        let board: [String: Any] = [
            "id": boardID.uuidString, "name": "Test Board",
            "extraColumns": [["id": columnID.uuidString, "name": "Todo", "isDone": false, "emoji": "📋"]],
            "cards": [],
        ]
        try JSONSerialization.data(withJSONObject: board)
            .write(to: boards.appendingPathComponent("\(boardID.uuidString).json"))
    }

    private func storedCards() throws -> [[String: Any]] {
        let url = storageRoot.appendingPathComponent("Boards/\(boardID.uuidString).json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return json?["cards"] as? [[String: Any]] ?? []
    }

    private func poll(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }
}
