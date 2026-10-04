import XCTest

/// Settings ▸ Boards line spacing widens the lines on the card face. Measured, because spacing
/// is a height, not an element. Each launch pins the setting with an argument, so the tester's
/// own value can't leak in.
///
/// Above 1× the edit fields are `SpacedTextField`, an AppKit field of the app's own, so this
/// suite also covers what the SwiftUI field did for free: focus that sticks, typing, the
/// line-break chord, Return, and blur committing to the store.
final class BoardLineSpacingUITests: XCTestCase {

    private var app: XCUIApplication!
    private var storageRoot: URL!
    private let boardID = UUID()
    private let columnID = UUID()

    override func setUpWithError() throws {
        continueAfterFailure = false
        storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeatPadUITests-\(UUID().uuidString)", isDirectory: true)
        try seedBoard()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: storageRoot)
    }

    func testSpacingWidensTheFaceAndTheFieldMatchesIt() throws {
        launch(lineSpacing: 1)
        let tight = settledHeight(of: notes)

        app.terminate()
        launch(lineSpacing: 1.8)
        let wide = settledHeight(of: notes)
        save("card-line-spacing-face")
        XCTAssertGreaterThan(wide, tight * 1.3, "1.8× spacing barely changed the notes (\(tight) → \(wide))")

        notes.click()
        XCTAssertTrue(app.textFields["card.notes"].waitForExistence(timeout: 5), "the notes never became a field")
        let editing = settledHeight(of: app.textFields["card.notes"])
        save("card-line-spacing-editing")
        XCTAssertEqual(editing, wide, accuracy: 2, "the notes jump height when clicked into (\(wide) → \(editing))")
    }

    func testSpacedNotesEditAndCommitOnBlur() throws {
        launch(lineSpacing: 1.8)
        notes.click()
        let field = app.textFields["card.notes"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the notes never became a field")
        sleep(1)
        XCTAssertTrue(field.exists, "the field dropped focus and closed on its own")
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText(" more")
        app.typeKey(.return, modifierFlags: .shift)
        app.typeText("next")
        XCTAssertTrue((field.value as? String ?? "").hasSuffix("more\nnext"),
                      "typing or ⇧⏎ went missing: \(String(describing: field.value))")
        app.staticTexts["Todo"].firstMatch.click()   // blur
        XCTAssertTrue(poll { ((try? self.storedCard()["body"]) as? String ?? "").hasSuffix("more\nnext") },
                      "blur did not commit: \(String(describing: try? storedCard()["body"]))")
        XCTAssertFalse(field.exists, "the notes stayed a field after blur")
    }

    func testSpacedTitleSubmitsOnReturn() throws {
        launch(lineSpacing: 1.8)
        let title = app.descendants(matching: .any).matching(identifier: "card.title").firstMatch
        title.click()
        let field = app.textFields["card.title"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the title never became a field")
        app.typeText("!")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(poll { (try? self.storedCard()["title"]) as? String == "Spacing!" },
                      "Return did not commit the title: \(String(describing: try? storedCard()["title"]))")
        XCTAssertTrue(poll { !field.exists }, "Return left the title a field")
    }

    func testSettingsShowBothLineSpacingSteppers() throws {
        launch(lineSpacing: 1)
        app.typeKey(",", modifierFlags: .command)
        let notesStepper = app.descendants(matching: .any).matching(identifier: "settings.notes.lineSpacing").firstMatch
        XCTAssertTrue(notesStepper.waitForExistence(timeout: 10), "General has no notes line spacing")
        save("settings-general")
        XCTAssertTrue(onScreen(notesStepper), "the notes line spacing row is clipped")
        // The tab's identifier does not always reach the toolbar button; its name does.
        app.toolbars.buttons["Boards"].firstMatch.click()
        let cardStepper = app.descendants(matching: .any).matching(identifier: "settings.board.lineSpacing").firstMatch
        XCTAssertTrue(cardStepper.waitForExistence(timeout: 10), "Boards has no card line spacing")
        save("settings-boards")
        XCTAssertTrue(onScreen(cardStepper), "the card line spacing row is clipped")
    }

    // MARK: - Helpers

    /// Inside the Settings window. `isHittable` reads false for a stepper inside the Boards
    /// tab's scroll panel even when it is plainly on screen.
    private func onScreen(_ element: XCUIElement) -> Bool {
        let window = app.windows.firstMatch.frame
        return !element.frame.isEmpty && window.contains(element.frame)
    }

    private func poll(_ condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if condition() { return true }
            usleep(200_000)
        }
        return false
    }

    private func storedCard() throws -> [String: Any] {
        let url = storageRoot.appendingPathComponent("Boards/\(boardID.uuidString).json")
        let board = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return (board?["cards"] as? [[String: Any]])?.first ?? [:]
    }

    private var notes: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "card.notes").firstMatch
    }

    private func launch(lineSpacing: Double) {
        app = XCUIApplication()
        app.launchArguments = [
            "-meatpad.storageRootOverride", storageRoot.path,
            "-meatpad.revealBoard", boardID.uuidString,
            "-hasSeenFirstRunIntro", "YES",
            "-board.lineSpacing", String(lineSpacing),
        ]
        app.launch()
        XCTAssertTrue(notes.waitForExistence(timeout: 20), "board never rendered")
        // Full display opens the notes; the other two fold them to one line.
        let full = app.radioButtons["Full"]
        XCTAssertTrue(full.waitForExistence(timeout: 5), "no Full segment in the card display control")
        full.click()
    }

    /// One read after a fixed settle — see `BoardCardDisplayUITests.settledTitleHeight`.
    private func settledHeight(of element: XCUIElement) -> CGFloat {
        usleep(2_000_000)
        XCTAssertTrue(element.waitForExistence(timeout: 5), "the notes row went missing")
        return element.frame.height
    }

    private func save(_ name: String) {
        let data = app.windows.firstMatch.screenshot().pngRepresentation
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
        try? data.write(to: url)
        print("SHOT_WROTE \(url.path) \(data.count)")
    }

    private func seedBoard() throws {
        let boards = storageRoot.appendingPathComponent("Boards", isDirectory: true)
        try FileManager.default.createDirectory(at: boards, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["boardOrder": [boardID.uuidString]])
            .write(to: boards.appendingPathComponent("boards.json"))
        let stamp = "2026-08-24T09:00:00Z"
        let board: [String: Any] = [
            "id": boardID.uuidString,
            "name": "Test Board",
            "extraColumns": [["id": columnID.uuidString, "name": "Todo", "isDone": false, "emoji": "📋"]],
            "cards": [[
                "id": UUID().uuidString,
                "title": "Spacing",
                "body": "First line of the notes, long enough that a card column has to wrap it onto a second line\nsecond line\nthird line",
                "columnID": columnID.uuidString,
                "created": stamp,
                "modified": stamp,
            ]],
        ]
        try JSONSerialization.data(withJSONObject: board)
            .write(to: boards.appendingPathComponent("\(boardID.uuidString).json"))
    }
}
