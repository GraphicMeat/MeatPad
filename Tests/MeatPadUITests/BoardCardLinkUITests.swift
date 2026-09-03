import XCTest

/// A URL on a card face has to take its own click and open, while every other click on the
/// same row still opens the field. That split lives entirely in SwiftUI's hit testing — the
/// tap-to-edit gesture sits on a layer *behind* the text so a link glyph can claim its click
/// first — and nothing below the window can see which of the two happened.
final class BoardCardLinkUITests: XCTestCase {
    private var app: XCUIApplication!
    private var storageRoot: URL!
    private let boardID = UUID()
    private let columnID = UUID()
    private let linkCardID = UUID()
    private let plainCardID = UUID()

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
            // Clicking a real link would otherwise hand the machine to Safari mid-test.
            "-meatpad.suppressLinkOpen", "YES",
        ]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "card.notes").firstMatch
            .waitForExistence(timeout: 20), "board never rendered")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: storageRoot)
    }

    /// The notes row of whichever card carries `text`. Cards are told apart by their content,
    /// not by index — column order is the board's business, not this test's.
    private func notesRow(containing text: String) -> XCUIElement {
        let rows = app.descendants(matching: .any).matching(identifier: "card.notes")
        for row in rows.allElementsBoundByIndex where ((row.value as? String) ?? row.label).contains(text) {
            return row
        }
        return rows.firstMatch
    }

    /// Near the leading edge, where the row's first characters are — the centre of a
    /// full-width row can be past the end of a short line, which would prove nothing.
    private func clickOnText(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.5)).tap()
    }

    func testClickingAURLDoesNotOpenTheField() throws {
        let row = notesRow(containing: "example.com")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        // How a card's link is drawn is a look, not an assertion — the PNG (path printed as
        // SHOT_WROTE) is there for a human to check when one of these tests starts arguing.
        saveShot("card-with-link")
        clickOnText(row)

        XCTAssertFalse(app.textFields["card.notes"].waitForExistence(timeout: 3),
                       "the click on a link opened the editor instead of the link")
    }

    func testClickingPlainNotesStillOpensTheField() throws {
        let row = notesRow(containing: "plain notes")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        clickOnText(row)

        XCTAssertTrue(app.textFields["card.notes"].waitForExistence(timeout: 5),
                      "a click on ordinary text no longer reaches the edit layer behind it")
    }

    /// The runner is sandboxed out of /private/tmp, so the PNG goes to its own container
    /// tmp and the path is printed for whoever is driving the run.
    private func saveShot(_ name: String) {
        let data = app.windows.firstMatch.screenshot().pngRepresentation
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
        try? data.write(to: url)
        print("SHOT_WROTE \(url.path) \(data.count)")
    }

    // MARK: - Seeding

    private func seedBoard() throws {
        let boards = storageRoot.appendingPathComponent("Boards", isDirectory: true)
        try FileManager.default.createDirectory(at: boards, withIntermediateDirectories: true)
        let index: [String: Any] = [
            "boardOrder": [boardID.uuidString],
            "globalColumns": [["id": columnID.uuidString, "name": "Todo", "isDone": false, "emoji": "📋"]],
        ]
        try JSONSerialization.data(withJSONObject: index).write(to: boards.appendingPathComponent("boards.json"))
        let stamp = "2026-09-03T09:00:00Z"
        let card: (UUID, String, String) -> [String: Any] = { id, title, body in
            [
                "id": id.uuidString, "title": title, "body": body,
                "columnID": self.columnID.uuidString, "created": stamp, "modified": stamp,
            ]
        }
        let board: [String: Any] = [
            "id": boardID.uuidString, "name": "Test Board", "extraColumns": [],
            "cards": [
                card(linkCardID, "Linked", "https://example.com"),
                card(plainCardID, "Plain", "plain notes here"),
            ],
        ]
        try JSONSerialization.data(withJSONObject: board).write(to: boards.appendingPathComponent("\(boardID.uuidString).json"))
    }
}
