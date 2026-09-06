import XCTest

/// A board's icon end to end: what the sidebar row draws for a seeded emoji and for a seeded
/// image, and what the row's own context menu does to it. The store unit-tests the file
/// bookkeeping; what only this can reach is whether the row is wired to it at all — the half
/// of every board feature that has historically broken.
///
/// Two boards are seeded, one of each kind, so "the emoji one" and "the image one" are both
/// on screen in every test. Each run gets its own storage root, thrown away after.
final class BoardIconUITests: XCTestCase {

    private var app: XCUIApplication!
    private var storageRoot = URL(fileURLWithPath: "/")
    private var emojiBoard = UUID()
    private var imageBoard = UUID()
    private var plainBoard = UUID()
    private var columnID = UUID()

    override func setUpWithError() throws {
        continueAfterFailure = false
        storageRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MeatPadUITests-\(UUID().uuidString)", isDirectory: true)
        emojiBoard = UUID()
        imageBoard = UUID()
        plainBoard = UUID()
        columnID = UUID()
        try seedBoards()

        app = XCUIApplication()
        app.launchArguments = [
            "-meatpad.storageRootOverride", storageRoot.path,
            "-meatpad.revealBoard", "all",
            "-hasSeenFirstRunIntro", "YES",
        ]
        app.launch()
        if !icon(emojiBoard).waitForExistence(timeout: 20) {
                XCTFail("the sidebar never listed the boards")
        }
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: storageRoot)
    }

    // MARK: - Tests

    func testASeededEmojiIsDrawnOnItsSidebarRow() {
        XCTAssertEqual(icon(emojiBoard).value as? String, "🚀")
    }

    func testASeededImageIsDrawnOnItsSidebarRow() {
        XCTAssertEqual(icon(imageBoard).value as? String, "image")
    }

    func testABoardWithNeitherKeepsTheDefaultIcon() throws {
        // The third seeded board carries no icon at all — the row still has to render.
        XCTAssertEqual(icon(plainBoard).value as? String, "none")
    }

    /// The whole point of the context menu: pick an emoji, watch the row change.
    func testSettingAnEmojiFromTheContextMenuUpdatesTheRow() throws {
        try setEmoji("🎯", on: plainBoard)

        XCTAssertTrue(poll { self.icon(self.plainBoard).value as? String == "🎯" },
                      "the row still shows \(String(describing: icon(plainBoard).value))")
        XCTAssertEqual(try stored(plainBoard)["icon"] as? String, "🎯")
    }

    /// One look per board: giving the image board an emoji drops the image, file and all.
    func testGivingTheImageBoardAnEmojiDropsTheImage() throws {
        try setEmoji("🎯", on: imageBoard)

        XCTAssertTrue(poll { self.icon(self.imageBoard).value as? String == "🎯" }, "the row kept the image")
        XCTAssertTrue(poll { (try? self.stored(self.imageBoard)["image"]) as? String == nil },
                      "the board file kept the image name")
        XCTAssertFalse(FileManager.default.fileExists(atPath: seededImageURL.path),
                       "the replaced image file was orphaned on disk")
    }

    func testRemovingTheIconPutsTheRowBackToTheDefault() throws {
        contextMenuItem("Remove Icon", on: emojiBoard).click()

        XCTAssertTrue(poll { self.icon(self.emojiBoard).value as? String == "none" },
                      "the row still shows \(String(describing: icon(emojiBoard).value))")
        XCTAssertTrue(poll { (try? self.stored(self.emojiBoard)["icon"]) as? String == nil },
                      "the board file kept the emoji")
    }

    func testTheIconSurvivesARelaunch() throws {
        try setEmoji("🎯", on: plainBoard)
        XCTAssertTrue(poll { self.icon(self.plainBoard).value as? String == "🎯" })

        app.terminate()
        app.launch()

        XCTAssertTrue(icon(plainBoard).waitForExistence(timeout: 20), "the sidebar never came back")
        XCTAssertEqual(icon(plainBoard).value as? String, "🎯")
    }

    // MARK: - Driving the sidebar

    private func icon(_ board: UUID) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "board.icon.\(board.uuidString)").firstMatch
    }

    /// The row's context menu, retried: the menu occasionally does not come up on the first
    /// right-click after the window takes focus, and every item's presence is asserted here
    /// rather than in each test.
    private func contextMenuItem(_ title: String, on board: UUID) -> XCUIElement {
        let row = icon(board)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no sidebar row for \(board)")
        let item = app.menuItems[title].firstMatch
        for _ in 0..<3 {
            row.rightClick()
            if item.waitForExistence(timeout: 3) { return item }
            // A menu that opened without the item would swallow the next right-click.
            app.typeKey(.escape, modifierFlags: [])
        }
        XCTFail("no \(title) item in the board's context menu")
        return item
    }

    /// Typed emoji do not survive XCUITest's key events; the pasteboard does. The field is a
    /// plain `TextField`, so ⌘V is all it takes.
    private func setEmoji(_ emoji: String, on board: UUID) throws {
        contextMenuItem("Set Emoji…", on: board).click()

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

    private func stored(_ board: UUID) throws -> [String: Any] {
        let url = storageRoot.appendingPathComponent("Boards/\(board.uuidString).json")
        let object = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any])
    }

    // MARK: - Seeding

    private var seededImageURL: URL {
        storageRoot.appendingPathComponent("Boards/Attachments/\(imageBoard.uuidString)/seed.png")
    }

    /// Writes the same files `BoardStore` would: `Boards/boards.json`, one file per board, and
    /// the image board's file on disk — a name on the record with nothing behind it would let
    /// the image row pass on a thumbnail that never decoded.
    private func seedBoards() throws {
        let boards = storageRoot.appendingPathComponent("Boards", isDirectory: true)
        try FileManager.default.createDirectory(at: boards, withIntermediateDirectories: true)

        let index: [String: Any] = [
            "boardOrder": [emojiBoard.uuidString, imageBoard.uuidString, plainBoard.uuidString],
            "globalColumns": [["id": columnID.uuidString, "name": "Todo", "isDone": false, "emoji": "📋"]],
        ]
        try JSONSerialization.data(withJSONObject: index).write(to: boards.appendingPathComponent("boards.json"))

        for (id, name, extra) in [
            (emojiBoard, "Emoji Board", ["icon": "🚀"]),
            (imageBoard, "Image Board", ["image": "seed.png"]),
            (plainBoard, "Plain Board", [:]),
        ] as [(UUID, String, [String: Any])] {
            var board: [String: Any] = ["id": id.uuidString, "name": name, "extraColumns": [], "cards": []]
            board.merge(extra) { _, new in new }
            try JSONSerialization.data(withJSONObject: board)
                .write(to: boards.appendingPathComponent("\(id.uuidString).json"))
        }

        try FileManager.default.createDirectory(at: seededImageURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Self.onePixelPNG.write(to: seededImageURL)
    }

    /// A 1×1 red PNG — the smallest thing `CGImageSource` will make a thumbnail out of.
    private static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==")!
}
