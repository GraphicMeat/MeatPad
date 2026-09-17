import XCTest

/// Column reorder: the ⋯ menu's Move Left/Right, and dragging a column header onto another
/// column's leading or trailing half. The arithmetic (`BoardDropPlacement.columnIndex`) and the
/// store write (`BoardStore.moveColumn`) are unit-tested; what only this can reach is whether
/// the header is wired to drag at all, and whether the menu items land on the right board.
final class BoardColumnOrderUITests: XCTestCase {
    private var app: XCUIApplication!
    private var storageRoot: URL!
    private let boardA = UUID()
    private let boardB = UUID()
    private let todoID = UUID()
    private let inProgressID = UUID()
    private let doneID = UUID()

    override func setUpWithError() throws {
        continueAfterFailure = false
        storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeatPadUITests-\(UUID().uuidString)", isDirectory: true)
        try seedBoards()
        app = XCUIApplication()
        app.launchArguments = [
            "-meatpad.storageRootOverride", storageRoot.path,
            "-meatpad.revealBoard", boardA.uuidString,
            "-hasSeenFirstRunIntro", "YES",
        ]
        app.launch()
        XCTAssertTrue(names.firstMatch.waitForExistence(timeout: 20), "board never rendered")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: storageRoot)
    }

    /// The menu writes only the board it was opened on — its sibling board, sharing the same
    /// global columns, keeps the default order.
    func testMoveRightMenuMovesColumnOnThisBoardOnly() throws {
        openColumnMenuItem("Move Right", on: todoID).click()

        XCTAssertTrue(poll { self.headerOrder() == ["In Progress", "Todo", "Done"] },
                      "header shows \(headerOrder())")
        XCTAssertEqual(storedColumnOrder(boardA), [inProgressID, todoID, doneID])

        selectSidebarRow(named: "Board B")

        XCTAssertTrue(poll { self.headerOrder() == ["Todo", "In Progress", "Done"] },
                      "board B shows \(headerOrder())")
        XCTAssertNil(storedColumnOrder(boardB), "board B grew a columnOrder of its own")
    }

    /// A press-drag on the header, dropped on the trailing half of the last column, moves it
    /// to the end — and takes only itself: every card stays put in its own column.
    func testDraggingColumnHeaderOntoTrailingHalfOfLastColumnMovesItToTheEnd() throws {
        // The column's own ⋯ button sits at the header's trailing edge, near the column's
        // right edge — a reliable "trailing half" target without guessing pixel offsets
        // against the name text's own (much narrower) frame.
        let doneMenuButton = columnActionsButton(doneID)
        XCTAssertTrue(doneMenuButton.waitForExistence(timeout: 5))
        let target = doneMenuButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: -20, dy: 0))

        let source = header("Todo").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        source.press(forDuration: 0.3, thenDragTo: target)

        XCTAssertTrue(poll { self.headerOrder() == ["In Progress", "Done", "Todo"] },
                      "header shows \(headerOrder())")
        XCTAssertEqual(storedColumn(ofCardTitled: "Todo Card"), todoID.uuidString, "the Todo card left its column")
        XCTAssertEqual(storedColumn(ofCardTitled: "In Progress Card"), inProgressID.uuidString, "the In Progress card left its column")
        XCTAssertEqual(storedColumn(ofCardTitled: "Done Card"), doneID.uuidString, "the Done card left its column")
    }

    // MARK: - Reading the board

    private var names: XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "column.name")
    }

    /// Like `BoardCardFaceUITests.faceText`: an idle `Text` row in this app exposes its
    /// content via AX `value`, not `label` — confirmed by dumping both mid-test.
    private func nameText(_ element: XCUIElement) -> String {
        element.value as? String ?? element.label
    }

    private func header(_ name: String) -> XCUIElement {
        XCTAssertTrue(names.firstMatch.waitForExistence(timeout: 5))
        let all = names.allElementsBoundByIndex
        guard let element = all.first(where: { nameText($0) == name }) else {
            XCTFail("no column named \(name) among \(all.map(nameText))")
            return names.firstMatch
        }
        return element
    }

    /// Left-to-right reading of the column headers currently on screen.
    private func headerOrder() -> [String] {
        usleep(500_000)
        _ = names.firstMatch.waitForExistence(timeout: 5)
        return names.allElementsBoundByIndex
            .sorted { $0.frame.minX < $1.frame.minX }
            .map(nameText)
    }

    private func columnActionsButton(_ column: UUID) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "column.actions.\(column.uuidString)").firstMatch
    }

    /// Opens the column's ⋯ menu and returns the requested item, asserting it exists — same
    /// pattern `BoardArchiveUITests` uses for its own column menu.
    private func openColumnMenuItem(_ title: String, on column: UUID) -> XCUIElement {
        let button = columnActionsButton(column)
        XCTAssertTrue(button.waitForExistence(timeout: 5), "no column actions button")
        button.click()
        let item = app.menuItems[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no “\(title)” item in the column menu")
        return item
    }

    private func selectSidebarRow(named name: String) {
        let row = app.staticTexts[name].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no sidebar row named \(name)")
        row.click()
        XCTAssertTrue(poll { self.headerOrder().first != nil }, "board never switched")
    }

    private func poll(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline { if condition() { return true }; usleep(200_000) }
        return false
    }

    // MARK: - Reading what was written

    private func boardJSON(_ id: UUID) -> [String: Any] {
        let url = storageRoot.appendingPathComponent("Boards/\(id.uuidString).json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    private func storedColumnOrder(_ board: UUID) -> [UUID]? {
        (boardJSON(board)["columnOrder"] as? [String])?.compactMap(UUID.init(uuidString:))
    }

    private func storedColumn(ofCardTitled title: String) -> String? {
        (boardJSON(boardA)["cards"] as? [[String: Any]])?
            .first { $0["title"] as? String == title }?["columnID"] as? String
    }

    // MARK: - Seeding

    private func seedBoards() throws {
        let boards = storageRoot.appendingPathComponent("Boards", isDirectory: true)
        try FileManager.default.createDirectory(at: boards, withIntermediateDirectories: true)
        let index: [String: Any] = [
            "boardOrder": [boardA.uuidString, boardB.uuidString],
            "globalColumns": [
                ["id": todoID.uuidString, "name": "Todo", "isDone": false, "emoji": "📋"],
                ["id": inProgressID.uuidString, "name": "In Progress", "isDone": false, "emoji": "🚧"],
                ["id": doneID.uuidString, "name": "Done", "isDone": true, "emoji": "✅"],
            ],
        ]
        try JSONSerialization.data(withJSONObject: index).write(to: boards.appendingPathComponent("boards.json"))

        let stamp = "2026-09-15T09:00:00Z"
        // One card per column, so a wayward reorder that drags cards along with it (rather
        // than just the column) shows up as a moved `columnID`. Each board gets its own card
        // ids — the store assumes those are unique across every board.
        func cards() -> [[String: Any]] {
            [
                ["id": UUID().uuidString, "title": "Todo Card", "columnID": todoID.uuidString, "created": stamp, "modified": stamp],
                ["id": UUID().uuidString, "title": "In Progress Card", "columnID": inProgressID.uuidString, "created": stamp, "modified": stamp],
                ["id": UUID().uuidString, "title": "Done Card", "columnID": doneID.uuidString, "created": stamp, "modified": stamp],
            ]
        }
        for id in [boardA, boardB] {
            let board: [String: Any] = [
                "id": id.uuidString, "name": id == boardA ? "Board A" : "Board B",
                "extraColumns": [], "cards": cards(),
            ]
            try JSONSerialization.data(withJSONObject: board).write(to: boards.appendingPathComponent("\(id.uuidString).json"))
        }
    }
}
