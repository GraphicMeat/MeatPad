import XCTest

/// Multi-select on the board: click/⌘-click/⇧-click, "Select All Cards" in a column menu, the
/// keyboard shortcuts (Esc/⌫/⌦/⌘A), and the bulk selection bar (Archive/Unarchive, Delete, ✕).
/// MeatPadKit unit-tests `BoardSelection` itself in isolation; what only this can reach is
/// whether the board UI is actually wired to it.
///
/// Each run gets its own storage root, seeded on disk before launch and thrown away after.
final class BoardMultiSelectUITests: XCTestCase {

    private var app: XCUIApplication!
    private var storageRoot = URL(fileURLWithPath: "/")
    private var boardID = UUID()
    private var todoColumnID = UUID()
    private var doneColumnID = UUID()
    private var card1ID = UUID()
    private var card2ID = UUID()
    private var card3ID = UUID()
    private var card4ID = UUID()
    private var card5ID = UUID()

    override func setUpWithError() throws {
        continueAfterFailure = false
        storageRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MeatPadUITests-\(UUID().uuidString)", isDirectory: true)
        boardID = UUID()
        todoColumnID = UUID()
        doneColumnID = UUID()
        card1ID = UUID()
        card2ID = UUID()
        card3ID = UUID()
        card4ID = UUID()
        card5ID = UUID()
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

    func testCommandClickSelectsSeveralAndBarDeletesThemWithOneUndo() throws {
        let card1 = cardElement("Card 1")
        let card3 = cardElement("Card 3")
        XCTAssertTrue(card1.waitForExistence(timeout: 5))
        XCTAssertTrue(card3.waitForExistence(timeout: 5))

        card1.click()
        XCUIElement.perform(withKeyModifiers: .command) { card3.click() }

        XCTAssertTrue(waitForSelectionCount(contains: "2"), "selection bar never showed 2")

        let delete = app.buttons["board.selection.delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.click()

        XCTAssertTrue(poll { (try? self.storedCards().count) == 3 }, "expected 3 cards left, found \((try? storedCards().count) ?? -1)")

        let undo = app.buttons["board.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        undo.click()

        XCTAssertTrue(poll { (try? self.storedCards().count) == 5 }, "undo did not restore both cards")
    }

    func testShiftClickExtendsAndSelectAllCardsInColumnSelectsVisibleOnes() throws {
        let card1 = cardElement("Card 1")
        let card3 = cardElement("Card 3")
        XCTAssertTrue(card1.waitForExistence(timeout: 5))
        XCTAssertTrue(card3.waitForExistence(timeout: 5))

        card1.click()
        XCUIElement.perform(withKeyModifiers: .shift) { card3.click() }

        XCTAssertTrue(waitForSelectionCount(contains: "3"), "shift-click did not extend to 3")

        let selectAll = openColumnMenuItem("Select All Cards", columnID: todoColumnID)
        selectAll.click()

        XCTAssertTrue(waitForSelectionCount(contains: "4"), "Select All Cards did not select all 4 Todo cards")
    }

    func testDeleteKeyInTitleFieldDoesNotDeleteSelectedCards() throws {
        let card1 = cardElement("Card 1")
        let card2 = cardElement("Card 2")
        XCTAssertTrue(card1.waitForExistence(timeout: 5))
        XCTAssertTrue(card2.waitForExistence(timeout: 5))

        XCUIElement.perform(withKeyModifiers: .command) { card1.click() }
        XCUIElement.perform(withKeyModifiers: .command) { card2.click() }

        // Plain click on the title starts editing (⌘/⇧-click never does).
        card1.click()
        app.typeKey(.delete, modifierFlags: [])

        XCTAssertTrue(poll { (try? self.storedCards().count) == 5 }, "a card was deleted while a title field held focus")
    }

    func testEscapeClearsSelection() throws {
        let card1 = cardElement("Card 1")
        let card2 = cardElement("Card 2")
        XCTAssertTrue(card1.waitForExistence(timeout: 5))
        XCTAssertTrue(card2.waitForExistence(timeout: 5))

        XCUIElement.perform(withKeyModifiers: .command) { card1.click() }
        XCUIElement.perform(withKeyModifiers: .command) { card2.click() }
        XCTAssertTrue(waitForSelectionCount(contains: "2"), "selection bar never showed 2")

        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(poll { !self.selectionCountElement.exists }, "the selection bar stayed up after Escape")
    }

    func testArchiveSelectedHidesThem() throws {
        let card1 = cardElement("Card 1")
        let card2 = cardElement("Card 2")
        XCTAssertTrue(card1.waitForExistence(timeout: 5))
        XCTAssertTrue(card2.waitForExistence(timeout: 5))

        XCUIElement.perform(withKeyModifiers: .command) { card1.click() }
        XCUIElement.perform(withKeyModifiers: .command) { card2.click() }
        XCTAssertTrue(waitForSelectionCount(contains: "2"), "selection bar never showed 2")

        let archive = app.buttons["board.selection.archive"]
        XCTAssertTrue(archive.waitForExistence(timeout: 5))
        archive.click()

        XCTAssertTrue(waitForCardTitles(["Card 3", "Card 4", "Card 5"]), "visible cards: \(visibleCardTitles)")
        XCTAssertNotNil(try storedArchived(of: card1ID), "Card 1 never got archived")
        XCTAssertNotNil(try storedArchived(of: card2ID), "Card 2 never got archived")
    }

    // MARK: - Task 10: dragging a multi-card selection

    /// Dragging one card of a 3-card selection carries the whole selection, in visible order,
    /// to the drop slot — here across columns, Todo → Done — as one `store.grouped` block, so
    /// one ⌘Z undoes the whole move.
    func testDraggingOneOfThreeSelectedCardsMovesAllThreeInOrderWithOneUndo() throws {
        let card1 = cardElement("Card 1")
        let card2 = cardElement("Card 2")
        let card4 = cardElement("Card 4")
        let card5 = cardElement("Card 5")
        XCTAssertTrue(card1.waitForExistence(timeout: 5))
        XCTAssertTrue(card5.waitForExistence(timeout: 5))

        card1.click()
        XCUIElement.perform(withKeyModifiers: .command) { card2.click() }
        XCUIElement.perform(withKeyModifiers: .command) { card4.click() }
        XCTAssertTrue(waitForSelectionCount(contains: "3"), "selection bar never showed 3")

        // Drag from card 2 (one of the three selected) to just above card 5 in Done.
        center(of: card2).click(forDuration: 0.4, thenDragTo: top(of: card5, minus: 4))

        XCTAssertTrue(poll { (try? self.storedColumnTitles(self.doneColumnID)) == ["Card 1", "Card 2", "Card 4", "Card 5"] },
                      "Done order is \((try? storedColumnTitles(doneColumnID)) ?? [])")
        XCTAssertEqual(try storedColumnTitles(todoColumnID), ["Card 3"])

        let undo = app.buttons["board.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        undo.click()

        XCTAssertTrue(poll { (try? self.storedColumnTitles(self.todoColumnID)) == ["Card 1", "Card 2", "Card 3", "Card 4"] },
                      "undo did not restore Todo, got \((try? storedColumnTitles(todoColumnID)) ?? [])")
        XCTAssertEqual(try storedColumnTitles(doneColumnID), ["Card 5"])
    }

    /// Dropping a 2-card selection just above one of its own members (the two are already
    /// adjacent) is a no-op for column order.
    func testDroppingSelectionAboveOneOfItsOwnCardsKeepsOrder() throws {
        let card2 = cardElement("Card 2")
        let card3 = cardElement("Card 3")
        XCTAssertTrue(card2.waitForExistence(timeout: 5))
        XCTAssertTrue(card3.waitForExistence(timeout: 5))

        card2.click()
        XCUIElement.perform(withKeyModifiers: .command) { card3.click() }
        XCTAssertTrue(waitForSelectionCount(contains: "2"), "selection bar never showed 2")

        center(of: card2).click(forDuration: 0.4, thenDragTo: top(of: card3, minus: 4))

        XCTAssertTrue(poll { (try? self.storedColumnTitles(self.todoColumnID)) == ["Card 1", "Card 2", "Card 3", "Card 4"] },
                      "Todo order changed: \((try? storedColumnTitles(todoColumnID)) ?? [])")
    }

    // MARK: - Driving the board

    private func cardElement(_ title: String) -> XCUIElement {
        cardTitles.matching(NSPredicate(format: "value == %@", title)).firstMatch
    }

    private var selectionCountElement: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "board.selection.count").firstMatch
    }

    /// Like `BoardCardFaceUITests.faceText`/`BoardColumnOrderUITests.nameText`: an idle `Text`
    /// row in this app exposes its content via AX `value`, not `label`.
    private func waitForSelectionCount(contains substring: String, timeout: TimeInterval = 5) -> Bool {
        poll(timeout: timeout) {
            let el = self.selectionCountElement
            let text = (el.value as? String) ?? el.label
            return el.exists && text.contains(substring)
        }
    }

    /// Same idiom `BoardDropUITests` drags with: press-and-hold on a card's title (inside its
    /// row, so it still starts the row's own `.draggable`), then drag to a coordinate above or
    /// below another row's midline.
    private func center(of element: XCUIElement) -> XCUICoordinate {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    }
    private func top(of element: XCUIElement, minus dy: CGFloat) -> XCUICoordinate {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: -dy))
    }

    /// Opens a column's ⋯ menu and returns the requested item, asserting it exists.
    private func openColumnMenuItem(_ title: String, columnID: UUID) -> XCUIElement {
        let button = app.descendants(matching: .any).matching(identifier: "column.actions.\(columnID.uuidString)").firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "no column actions button")
        button.click()
        let item = app.menuItems[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no “\(title)” item in the column menu")
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

    private func storedCards() throws -> [[String: Any]] {
        try boardJSON()["cards"] as? [[String: Any]] ?? []
    }

    private func storedCard(_ id: UUID) throws -> [String: Any]? {
        try storedCards().first { $0["id"] as? String == id.uuidString }
    }

    private func storedArchived(of id: UUID) throws -> String? {
        try storedCard(id)?["archived"] as? String
    }

    /// One column's cards, in stored (= rendered) order, by title.
    private func storedColumnTitles(_ columnID: UUID) throws -> [String] {
        try storedCards()
            .filter { $0["columnID"] as? String == columnID.uuidString }
            .compactMap { $0["title"] as? String }
    }

    // MARK: - Seeding

    /// Writes the same files `BoardStore` would: `Boards/boards.json` plus one board file, two
    /// columns (Todo, Done), four cards in Todo and one in Done.
    private func seedBoard() throws {
        let boards = storageRoot.appendingPathComponent("Boards", isDirectory: true)
        try FileManager.default.createDirectory(at: boards, withIntermediateDirectories: true)

        let index: [String: Any] = ["boardOrder": [boardID.uuidString]]
        try JSONSerialization.data(withJSONObject: index)
            .write(to: boards.appendingPathComponent("boards.json"))
        let columns: [[String: Any]] = [
            ["id": todoColumnID.uuidString, "name": "Todo", "isDone": false, "emoji": "📋"],
            ["id": doneColumnID.uuidString, "name": "Done", "isDone": true, "emoji": "✅"],
        ]

        let stamp = "2026-09-15T09:00:00Z"
        var cards: [[String: Any]] = [card1ID, card2ID, card3ID, card4ID].enumerated().map { index, id in
            [
                "id": id.uuidString, "title": "Card \(index + 1)",
                "columnID": todoColumnID.uuidString, "created": stamp, "modified": stamp,
            ]
        }
        cards.append([
            "id": card5ID.uuidString, "title": "Card 5",
            "columnID": doneColumnID.uuidString, "created": stamp, "modified": stamp,
        ])
        let board: [String: Any] = [
            "id": boardID.uuidString, "name": "Test Board", "extraColumns": columns, "cards": cards,
        ]
        try JSONSerialization.data(withJSONObject: board)
            .write(to: boards.appendingPathComponent("\(boardID.uuidString).json"))
    }
}
