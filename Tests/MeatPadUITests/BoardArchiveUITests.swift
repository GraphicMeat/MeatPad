import XCTest

/// Archiving end to end: a column's "Archive All Cards" action and a card's own "Archive
/// Card" / "Unarchive Card" toggle. MeatPadKit unit-tests `Card.matches` and
/// `BoardStore.setArchived` in isolation; what only this can reach is whether the board UI is
/// wired to either of them at all.
///
/// Each run gets its own storage root, seeded on disk before launch and thrown away after.
final class BoardArchiveUITests: XCTestCase {

    private var app: XCUIApplication!
    private var storageRoot = URL(fileURLWithPath: "/")
    private var boardID = UUID()
    private var columnID = UUID()
    private var card1ID = UUID()
    private var card2ID = UUID()
    private var card3ID = UUID()
    private var archivedCardID = UUID()

    override func setUpWithError() throws {
        continueAfterFailure = false
        storageRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MeatPadUITests-\(UUID().uuidString)", isDirectory: true)
        boardID = UUID()
        columnID = UUID()
        card1ID = UUID()
        card2ID = UUID()
        card3ID = UUID()
        archivedCardID = UUID()
        try seedBoard()

        app = XCUIApplication()
        app.launchArguments = [
            "-meatpad.storageRootOverride", storageRoot.path,
            "-meatpad.revealBoard", boardID.uuidString,
            "-hasSeenFirstRunIntro", "YES",
        ]
        app.launch()
        XCTAssertTrue(cardTitles.firstMatch.waitForExistence(timeout: 20), "board never rendered")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: storageRoot)
    }

    // MARK: - Tests

    func testArchiveAllCardsHidesColumnCardsAndUndoBringsThemBack() throws {
        XCTAssertTrue(waitForCardTitles(["Card 1", "Card 2", "Card 3"]), "visible cards: \(visibleCardTitles)")

        let archiveAll = openColumnMenuItem("Archive All Cards")
        archiveAll.click()

        XCTAssertTrue(waitForCardTitles([]), "visible cards: \(visibleCardTitles)")
        for id in [card1ID, card2ID, card3ID] {
            XCTAssertNotNil(try storedArchived(of: id), "\(id) never got archived")
        }

        let undo = app.buttons["board.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        undo.click()

        XCTAssertTrue(waitForCardTitles(["Card 1", "Card 2", "Card 3"]), "undo did not restore the cards")
    }

    func testShowArchivedRevealsDimmedArchivedCardsAndUnarchiveRestores() throws {
        XCTAssertFalse(archivedTitle.exists, "the archived card showed before the toggle was on")

        let toggle = app.buttons["board.showArchived"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "off")
        toggle.click()

        XCTAssertTrue(archivedTitle.waitForExistence(timeout: 5), "the archived card never appeared")
        let badge = app.descendants(matching: .any).matching(identifier: "card.archived").firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 5), "no archivebox badge on the archived card")

        cardMenuItem("Unarchive Card", onCardTitled: "Archived Card").click()

        XCTAssertTrue(poll { self.archivedTitle.exists }, "the card disappeared instead of staying visible")
        XCTAssertNil(try storedArchived(of: archivedCardID), "the card is still stored as archived")
    }

    // MARK: - Driving the board

    private var archivedTitle: XCUIElement {
        cardTitles.matching(NSPredicate(format: "value == %@", "Archived Card")).firstMatch
    }

    /// Opens the column's ⋯ menu and returns the requested item, asserting it exists.
    private func openColumnMenuItem(_ title: String) -> XCUIElement {
        let button = app.descendants(matching: .any).matching(identifier: "column.actions.\(columnID.uuidString)").firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "no column actions button")
        button.click()
        let item = app.menuItems[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no “\(title)” item in the column menu")
        return item
    }

    /// The card's own context menu, retried the same way `BoardIconUITests` retries a board
    /// row's: the menu occasionally does not come up on the first right-click after the
    /// window takes focus.
    private func cardMenuItem(_ title: String, onCardTitled cardTitle: String) -> XCUIElement {
        let card = cardTitles.matching(NSPredicate(format: "value == %@", cardTitle)).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5), "no card titled “\(cardTitle)”")
        let item = app.menuItems[title].firstMatch
        for _ in 0..<3 {
            card.rightClick()
            if item.waitForExistence(timeout: 3) { return item }
            app.typeKey(.escape, modifierFlags: [])
        }
        XCTFail("no “\(title)” item in the card's context menu")
        return item
    }

    // MARK: - Reading the board

    /// `card.title` is a `Text` until the row is clicked and a `TextField` after, so the query
    /// can't name an element type. Its text is the value either way.
    private var cardTitles: XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "card.title")
    }

    private var visibleCardTitles: [String] {
        (0..<cardTitles.count)
            .map { cardTitles.element(boundBy: $0) }
            .map { $0.value as? String ?? $0.label }
            .sorted()
    }

    /// Polls rather than asserting once: a card leaves or rejoins the tree a frame or two
    /// after the action that changed it.
    private func waitForCardTitles(_ expected: [String]) -> Bool {
        poll { self.visibleCardTitles == expected.sorted() }
    }

    private func poll(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if condition() { return true }; usleep(200_000) }
        return false
    }

    // MARK: - Reading the store

    private func boardJSON() throws -> [String: Any] {
        let url = storageRoot.appendingPathComponent("Boards/\(boardID.uuidString).json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func storedCard(_ id: UUID) throws -> [String: Any]? {
        (try boardJSON()["cards"] as? [[String: Any]])?.first { $0["id"] as? String == id.uuidString }
    }

    private func storedArchived(of id: UUID) throws -> String? {
        try storedCard(id)?["archived"] as? String
    }

    // MARK: - Seeding

    /// Writes the same files `BoardStore` would: `Boards/boards.json` plus one board file, one
    /// column, three unarchived cards and one already carrying an `archived` date.
    private func seedBoard() throws {
        let boards = storageRoot.appendingPathComponent("Boards", isDirectory: true)
        try FileManager.default.createDirectory(at: boards, withIntermediateDirectories: true)

        let index: [String: Any] = [
            "boardOrder": [boardID.uuidString],
            "globalColumns": [
                ["id": columnID.uuidString, "name": "Todo", "isDone": false, "emoji": "📋"],
            ],
        ]
        try JSONSerialization.data(withJSONObject: index)
            .write(to: boards.appendingPathComponent("boards.json"))

        let stamp = "2026-09-15T09:00:00Z"
        var cards: [[String: Any]] = [card1ID, card2ID, card3ID].enumerated().map { index, id in
            [
                "id": id.uuidString, "title": "Card \(index + 1)",
                "columnID": columnID.uuidString, "created": stamp, "modified": stamp,
            ]
        }
        cards.append([
            "id": archivedCardID.uuidString, "title": "Archived Card",
            "columnID": columnID.uuidString, "created": stamp, "modified": stamp,
            "archived": "2026-09-01T09:00:00Z",
        ])
        let board: [String: Any] = [
            "id": boardID.uuidString, "name": "Test Board", "extraColumns": [], "cards": cards,
        ]
        try JSONSerialization.data(withJSONObject: board)
            .write(to: boards.appendingPathComponent("\(boardID.uuidString).json"))
    }
}
