import XCTest

/// Settings ▸ Boards line spacing widens the lines on the card face. Measured, because spacing
/// is a height, not an element. Each launch pins the setting with an argument, so the tester's
/// own value can't leak in.
///
/// The edit field is left out on purpose: a macOS `TextField` sizes from its cell and ignores
/// `.lineSpacing`, so above 1× the text closes up while it is edited (see `CardView.leading`).
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

    func testSpacingWidensTheFace() throws {
        launch(lineSpacing: 1)
        let tight = settledHeight(of: notes)

        app.terminate()
        launch(lineSpacing: 1.8)
        let wide = settledHeight(of: notes)
        save("card-line-spacing-face")
        XCTAssertGreaterThan(wide, tight * 1.3, "1.8× spacing barely changed the notes (\(tight) → \(wide))")
    }

    // MARK: - Helpers

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
                "body": "First line of the notes\nsecond line\nthird line\nfourth line",
                "columnID": columnID.uuidString,
                "created": stamp,
                "modified": stamp,
            ]],
        ]
        try JSONSerialization.data(withJSONObject: board)
            .write(to: boards.appendingPathComponent("\(boardID.uuidString).json"))
    }
}
