import XCTest

/// Markdown on a card face. The parsing is unit-tested in `CardMarkdownTests`; what only this
/// can say is whether the face is wired to it — and, just as importantly, that the field you
/// edit still holds the raw text, because rendering over the editor would silently eat the
/// user's own asterisks.
///
/// The face's accessibility value is the rendered plain text when markdown is on, so what
/// VoiceOver reads and what is drawn are the same thing.
final class BoardCardMarkdownUITests: XCTestCase {

    private var app: XCUIApplication!
    private var storageRoot = URL(fileURLWithPath: "/")
    private var boardID = UUID()
    private var columnID = UUID()
    private var cardID = UUID()

    override func setUpWithError() throws {
        continueAfterFailure = false
        storageRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MeatPadUITests-\(UUID().uuidString)", isDirectory: true)
        boardID = UUID()
        columnID = UUID()
        cardID = UUID()
        try seedBoard()
        app = XCUIApplication()
        app.launchArguments = launchArguments()
        app.launch()
        XCTAssertTrue(title.waitForExistence(timeout: 20), "the board never rendered")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: storageRoot)
    }

    private func launchArguments(markdown: Bool? = nil) -> [String] {
        var args = [
            "-meatpad.storageRootOverride", storageRoot.path,
            "-meatpad.revealBoard", boardID.uuidString,
            "-hasSeenFirstRunIntro", "YES",
            // Density is remembered across launches; pin it so a previous run cannot leave the
            // notes row folded shut under this test.
            "-board.cardDisplay", "full",
        ]
        // NSArgumentDomain wins over the stored AppStorage value, which is how a run pins the
        // setting without having to open Settings and click it.
        if let markdown { args += ["-board.markdown", markdown ? "YES" : "NO"] }
        return args
    }

    private var title: XCUIElement { app.descendants(matching: .any).matching(identifier: "card.title").firstMatch }
    private var notes: XCUIElement { app.descendants(matching: .any).matching(identifier: "card.notes").firstMatch }

    private func faceText(_ element: XCUIElement) -> String { (element.value as? String) ?? element.label }

    // MARK: - Tests

    /// On by default: the user never has to find the setting to get bold text.
    func testMarkdownIsRenderedOnTheFaceByDefault() {
        XCTAssertEqual(faceText(title), "Bold title")
    }

    func testAMarkdownLinkRendersAsItsLabel() {
        XCTAssertTrue(poll { self.faceText(self.notes) == "see the docs" },
                      "the notes face reads \(faceText(notes))")
    }

    /// The editor is the raw text, always — what you click into is what is stored.
    func testClickingTheTitleOpensAFieldHoldingTheRawMarkdown() {
        title.click()
        let field = app.textFields["card.title"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the click opened no field")
        XCTAssertEqual(field.value as? String, "**Bold** title")
    }

    /// The setting off: the face is the raw text again, exactly as it was before markdown.
    func testTurningTheSettingOffPutsTheRawTextBack() {
        app.terminate()
        app.launchArguments = launchArguments(markdown: false)
        app.launch()

        XCTAssertTrue(title.waitForExistence(timeout: 20), "the board never came back")
        XCTAssertEqual(faceText(title), "**Bold** title")
    }

    private func poll(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(200_000)
        }
        return false
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
            "extraColumns": [["id": columnID.uuidString, "name": "Todo", "isDone": false, "emoji": "📋"]],
            "cards": [[
                "id": cardID.uuidString, "title": "**Bold** title",
                "body": "see [the docs](https://example.com)",
                "columnID": columnID.uuidString, "created": stamp, "modified": stamp,
            ]],
        ]
        try JSONSerialization.data(withJSONObject: board)
            .write(to: boards.appendingPathComponent("\(boardID.uuidString).json"))
    }
}
