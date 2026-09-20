import XCTest

/// A column's own look — the emoji or image drawn ahead of its name. The store unit-tests the
/// file bookkeeping; only this can say whether the header is wired to it at all, which is the
/// half of every board feature that has historically shipped broken.
///
/// Two columns are seeded, one with an emoji and one with nothing, so both states are on
/// screen in every test.
final class BoardColumnIconUITests: XCTestCase {

    private var app: XCUIApplication!
    private var storageRoot = URL(fileURLWithPath: "/")
    private var boardID = UUID()
    private var emojiColumn = UUID()
    private var plainColumn = UUID()

    override func setUpWithError() throws {
        continueAfterFailure = false
        storageRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MeatPadUITests-\(UUID().uuidString)", isDirectory: true)
        boardID = UUID()
        emojiColumn = UUID()
        plainColumn = UUID()
        try seedBoard()

        app = XCUIApplication()
        app.launchArguments = [
            "-meatpad.storageRootOverride", storageRoot.path,
            "-meatpad.revealBoard", boardID.uuidString,
            "-hasSeenFirstRunIntro", "YES",
        ]
        app.launch()
        XCTAssertTrue(icon(emojiColumn).waitForExistence(timeout: 20), "the board never rendered its columns")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: storageRoot)
    }

    // MARK: - Tests

    func testASeededColumnEmojiIsDrawnInTheHeader() {
        XCTAssertEqual(icon(emojiColumn).value as? String, "📋")
    }

    /// A column with no icon draws nothing at all — no invented default glyph and no element
    /// standing in for one, so a board that never set an icon looks exactly as it did before
    /// columns could carry one.
    func testAColumnWithNoIconDrawsNothing() {
        XCTAssertFalse(icon(plainColumn).exists, "an iconless column grew an icon element")
    }

    func testSettingAnEmojiFromTheColumnMenuUpdatesTheHeader() throws {
        try setEmoji("🎯", on: plainColumn)

        XCTAssertTrue(poll { self.icon(self.plainColumn).value as? String == "🎯" },
                      "the header still shows \(String(describing: icon(plainColumn).value))")
        XCTAssertEqual(try storedColumn(plainColumn)["emoji"] as? String, "🎯")
    }

    func testRemovingTheIconPutsTheHeaderBackToPlain() throws {
        menuItem("Remove Icon", on: emojiColumn).click()

        XCTAssertTrue(poll { !self.icon(self.emojiColumn).exists },
                      "the header still shows \(String(describing: icon(emojiColumn).value))")
        XCTAssertTrue(poll { (try? self.storedColumn(self.emojiColumn)["emoji"]) as? String == nil },
                      "the board file kept the emoji")
    }

    func testTheColumnIconSurvivesARelaunch() throws {
        try setEmoji("🎯", on: plainColumn)
        XCTAssertTrue(poll { self.icon(self.plainColumn).value as? String == "🎯" })

        app.terminate()
        app.launch()

        XCTAssertTrue(icon(plainColumn).waitForExistence(timeout: 20), "the board never came back")
        XCTAssertEqual(icon(plainColumn).value as? String, "🎯")
    }

    // MARK: - Driving the header

    private func icon(_ column: UUID) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "column.icon.\(column.uuidString)").firstMatch
    }

    /// The column's ⋯ menu, retried: a menu occasionally does not come up on the first click
    /// after the window takes focus, and an opened-but-empty menu swallows the next one.
    private func menuItem(_ title: String, on column: UUID) -> XCUIElement {
        let button = app.descendants(matching: .any)
            .matching(identifier: "column.actions.\(column.uuidString)").firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "no actions menu for column \(column)")
        let item = app.menuItems[title].firstMatch
        for _ in 0..<3 {
            button.click()
            if item.waitForExistence(timeout: 3) { return item }
            app.typeKey(.escape, modifierFlags: [])
        }
        XCTFail("no \(title) item in the column's menu")
        return item
    }

    /// Typed emoji do not survive XCUITest's key events; the pasteboard does.
    private func setEmoji(_ emoji: String, on column: UUID) throws {
        menuItem("Set Emoji…", on: column).click()

        let field = app.textFields["namePrompt.name"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no sheet opened")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(emoji, forType: .string)
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeKey("v", modifierFlags: .command)
        app.buttons["namePrompt.commit"].firstMatch.click()
    }

    private func poll(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(200_000)
        }
        return false
    }

    // MARK: - Reading what was written

    private func storedColumn(_ column: UUID) throws -> [String: Any] {
        let url = storageRoot.appendingPathComponent("Boards/\(boardID.uuidString).json")
        let object = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        let board = try XCTUnwrap(object as? [String: Any])
        let columns = try XCTUnwrap(board["extraColumns"] as? [[String: Any]])
        return try XCTUnwrap(columns.first { $0["id"] as? String == column.uuidString })
    }

    // MARK: - Seeding

    private func seedBoard() throws {
        let boards = storageRoot.appendingPathComponent("Boards", isDirectory: true)
        try FileManager.default.createDirectory(at: boards, withIntermediateDirectories: true)
        let index: [String: Any] = ["boardOrder": [boardID.uuidString]]
        try JSONSerialization.data(withJSONObject: index).write(to: boards.appendingPathComponent("boards.json"))

        let stamp = "2026-09-20T09:00:00Z"
        let board: [String: Any] = [
            "id": boardID.uuidString, "name": "Test Board",
            "extraColumns": [
                ["id": emojiColumn.uuidString, "name": "Todo", "isDone": false, "emoji": "📋"],
                ["id": plainColumn.uuidString, "name": "Doing", "isDone": false],
            ],
            "cards": [[
                "id": UUID().uuidString, "title": "Alpha", "columnID": emojiColumn.uuidString,
                "created": stamp, "modified": stamp,
            ]],
        ]
        try JSONSerialization.data(withJSONObject: board)
            .write(to: boards.appendingPathComponent("\(boardID.uuidString).json"))
    }
}
