import XCTest

/// Showing a card, and showing a board. Both are pure layout — the card is scaled by an
/// environment value that no unit test can see, and the button that presents it only earns
/// its space in the card header while the pointer is over the card.
final class BoardPresentUITests: XCTestCase {
    private var app: XCUIApplication!
    private var storageRoot: URL!
    private let boardID = UUID()
    private let columnID = UUID()
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

    /// The presented copy is the widest `card.title` on screen — the row in the column keeps
    /// its own size behind the backdrop.
    private func widestTitle() -> CGFloat {
        app.descendants(matching: .any).matching(identifier: "card.title")
            .allElementsBoundByIndex.map(\.frame.width).max() ?? 0
    }

    func testThePresentButtonPresentsTheCardAndPlusGrowsIt() throws {
        try present()
        let close = app.buttons["board.present.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "the present button presented nothing")

        let presented = widestTitle()
        app.buttons["board.present.larger"].click()
        XCTAssertTrue(poll { self.widestTitle() > presented + 1 }, "+ did not grow the card")
        try shoot("present")

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(poll { !close.exists }, "Escape left the card presented")
    }

    /// The +/- and close buttons are parked in a corner of the overlay: growing the card must
    /// not walk them out from under the cursor between two clicks.
    func testPresentControlsStayPutWhenTheCardGrows() throws {
        try present()
        let close = app.buttons["board.present.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "the present button presented nothing")
        let parked = close.frame

        let grown = widestTitle()
        app.buttons["board.present.larger"].click()
        XCTAssertTrue(poll { self.widestTitle() > grown + 1 }, "+ did not grow the card")
        XCTAssertEqual(close.frame.origin.x, parked.origin.x, accuracy: 1, "the controls moved sideways")
        XCTAssertEqual(close.frame.origin.y, parked.origin.y, accuracy: 1, "the controls moved with the card")
    }

    func testPresentationModeGrowsCards() throws {
        let toggle = app.buttons["board.presentation"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        // Remembered across launches, so the run may start with it on: read the state back
        // from the button rather than pinning it through a launch argument, which lands in
        // NSArgumentDomain and overrides every read — the toggle could never be observed.
        if toggle.value as? String == "on" { toggle.click() }
        XCTAssertTrue(poll { toggle.value as? String == "off" })
        let normal = widestTitle()

        toggle.click()
        XCTAssertTrue(poll { self.widestTitle() > normal + 1 }, "presentation mode did not grow the cards")
        try shoot("presentation-mode")

        toggle.click()
        XCTAssertTrue(poll { abs(self.widestTitle() - normal) < 1 }, "leaving it did not restore the size")
    }

    /// A double-click on a card no longer presents it — the gesture belonged to the field
    /// editor underneath as much as to the card, so it is a button now. Hover first: the
    /// button is invisible until the pointer is over the card.
    private func present() throws {
        title.hover()
        let button = app.buttons["card.present"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "no present button on the card")
        button.click()
    }

    /// The double-click that used to present a card must not do it any more: it was taking
    /// the second click of every title edit with it.
    func testDoubleClickingACardNoLongerPresentsIt() throws {
        title.doubleClick()
        XCTAssertFalse(app.buttons["board.present.close"].waitForExistence(timeout: 3),
                       "a double click still presented the card")
    }

    /// Layout is signed off by eye from these — the runner's own tmp dir, because its sandbox
    /// cannot write anywhere else.
    private func shoot(_ name: String) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("present-\(name).png")
        try app.windows.firstMatch.screenshot().pngRepresentation.write(to: url)
        print("SHOT \(url.path)")
    }

    private func poll(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline { if condition() { return true }; usleep(200_000) }
        return false
    }

    // MARK: - Seeding

    private func seedBoard() throws {
        let boards = storageRoot.appendingPathComponent("Boards", isDirectory: true)
        try FileManager.default.createDirectory(at: boards, withIntermediateDirectories: true)
        let index: [String: Any] = ["boardOrder": [boardID.uuidString]]
        try JSONSerialization.data(withJSONObject: index).write(to: boards.appendingPathComponent("boards.json"))
        let stamp = "2026-09-03T09:00:00Z"
        let board: [String: Any] = [
            "id": boardID.uuidString, "name": "Test Board",
            "extraColumns": [["id": columnID.uuidString, "name": "Todo", "isDone": false, "emoji": "📋"]],
            "cards": [[
                "id": cardID.uuidString, "title": "Alpha", "body": "first line\nsecond line",
                "columnID": columnID.uuidString, "created": stamp, "modified": stamp,
            ]],
        ]
        try JSONSerialization.data(withJSONObject: board).write(to: boards.appendingPathComponent("\(boardID.uuidString).json"))
    }
}
