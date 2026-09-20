import XCTest

/// The sidebar's shape: what is pinned where, and what the sort menu does to the rows in
/// between. Pure layout — nothing here is visible to a unit test, and every board bug so far
/// has been a layout fault.
///
/// Three boards are seeded in an order that is neither alphabetical nor creation order, so a
/// sort that silently does nothing cannot pass.
final class SidebarOrderUITests: XCTestCase {

    private var app: XCUIApplication!
    private var storageRoot = URL(fileURLWithPath: "/")
    private var boards: [(id: UUID, name: String, created: String)] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
        storageRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MeatPadUITests-\(UUID().uuidString)", isDirectory: true)
        boards = [
            (UUID(), "Zebra", "2026-01-01T09:00:00Z"),
            (UUID(), "Apple", "2026-03-01T09:00:00Z"),
            (UUID(), "Mango", "2026-02-01T09:00:00Z"),
        ]
        try seedBoards()

        app = XCUIApplication()
        app.launchArguments = [
            "-meatpad.storageRootOverride", storageRoot.path,
            "-meatpad.revealBoard", "all",
            "-hasSeenFirstRunIntro", "YES",
            // Nothing in this suite may hand the machine over to a browser or Mail.
            "-meatpad.suppressLinkOpen", "YES",
        ]
        app.launch()
        XCTAssertTrue(row("Zebra").waitForExistence(timeout: 20), "the sidebar never listed the boards")
        // The sort is remembered across launches, so a previous run's would decide what this
        // one sees. Reset through the menu, never a launch argument: an argument lands in
        // NSArgumentDomain, which overrides every *read* of the key — the app would write the
        // new sort and keep reading the argument back, and nothing would ever reorder.
        try sortBoards(by: "Manual")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: storageRoot)
    }

    // MARK: - Tests

    /// The item the user asked for by name: Board Trash sits above New Board, the way Trash
    /// already sits above New Folder.
    func testBoardTrashSitsAboveNewBoard() {
        let trash = row("Board Trash")
        let new = app.descendants(matching: .any).matching(identifier: "sidebar.newBoard").firstMatch
        XCTAssertTrue(trash.waitForExistence(timeout: 10), "no Board Trash row")
        XCTAssertTrue(new.waitForExistence(timeout: 10), "no New Board row")
        XCTAssertLessThan(trash.frame.minY, new.frame.minY, "Board Trash is still below New Board")
    }

    func testTrashSitsAboveNewFolder() {
        let trash = row("Trash")
        let new = row("New Folder")
        XCTAssertTrue(trash.waitForExistence(timeout: 10), "no Trash row")
        XCTAssertTrue(new.waitForExistence(timeout: 10), "no New Folder row")
        XCTAssertLessThan(trash.frame.minY, new.frame.minY, "Trash is below New Folder")
    }

    /// All Boards is pinned first in its section and never sorts with the boards.
    func testAllBoardsStaysFirstWhateverTheSort() throws {
        try sortBoards(by: "Name")
        XCTAssertTrue(poll { self.orderedBoardNames().first == "Apple" }, "the boards never sorted")
        XCTAssertLessThan(row("All Boards").frame.minY, row("Apple").frame.minY,
                          "All Boards fell below a board")
    }

    func testSortingBoardsByNameReordersThem() throws {
        XCTAssertEqual(orderedBoardNames(), ["Zebra", "Apple", "Mango"], "the seeded order did not survive launch")

        try sortBoards(by: "Name")

        XCTAssertTrue(poll { self.orderedBoardNames() == ["Apple", "Mango", "Zebra"] },
                      "name order reads \(orderedBoardNames())")
    }

    func testSortingBoardsByDateCreatedReordersThem() throws {
        try sortBoards(by: "Date Created")

        XCTAssertTrue(poll { self.orderedBoardNames() == ["Zebra", "Mango", "Apple"] },
                      "created order reads \(orderedBoardNames())")
    }

    /// The pinned rows stay pinned: sorting must never lift Board Trash or New Board into the
    /// sorted run.
    func testSortingLeavesTheTrailingRowsPinned() throws {
        try sortBoards(by: "Name")
        XCTAssertTrue(poll { self.orderedBoardNames() == ["Apple", "Mango", "Zebra"] })

        let new = app.descendants(matching: .any).matching(identifier: "sidebar.newBoard").firstMatch
        XCTAssertLessThan(row("Zebra").frame.minY, row("Board Trash").frame.minY)
        XCTAssertLessThan(row("Board Trash").frame.minY, new.frame.minY)
    }

    func testTheSortSurvivesARelaunch() throws {
        try sortBoards(by: "Name")
        XCTAssertTrue(poll { self.orderedBoardNames() == ["Apple", "Mango", "Zebra"] })

        app.terminate()
        // Without the pinning arguments this time — NSArgumentDomain would override what the
        // app just stored.
        app.launchArguments = [
            "-meatpad.storageRootOverride", storageRoot.path,
            "-meatpad.revealBoard", "all",
            "-hasSeenFirstRunIntro", "YES",
        ]
        app.launch()

        XCTAssertTrue(row("Apple").waitForExistence(timeout: 20), "the sidebar never came back")
        XCTAssertEqual(orderedBoardNames(), ["Apple", "Mango", "Zebra"])
    }

    // MARK: - Studio footer

    /// The footer is pinned under the list, so it is there whatever the sidebar is scrolled
    /// to — and every one of its buttons has to exist, because a dead link in the corner of
    /// the window is the kind of thing nobody notices until a user reports it.
    func testTheStudioFooterOffersEveryLink() {
        for identifier in ["sidebar.studio", "sidebar.suggest", "sidebar.bug",
                           "sidebar.mailvault", "sidebar.photobooks"] {
            let button = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 10), "no \(identifier) button in the sidebar footer")
            XCTAssertTrue(button.isHittable, "\(identifier) is not clickable")
        }
    }

    /// Clicking one must not hand the machine over to a browser: every link goes through
    /// `LinkOpener`, which the launch argument silences.
    func testClickingAFooterLinkOpensNothingWhenSuppressed() {
        let studio = app.descendants(matching: .any).matching(identifier: "sidebar.studio").firstMatch
        XCTAssertTrue(studio.waitForExistence(timeout: 10))
        studio.click()
        XCTAssertTrue(row("All Boards").waitForExistence(timeout: 5), "the click disturbed the sidebar")
    }

    // MARK: - Driving the sidebar

    /// A selectable row's title is a `staticText`; an action row ("New Folder") is a `Button`
    /// that folds its label into its own element, so both element types have to be tried.
    private func row(_ name: String) -> XCUIElement {
        let text = app.staticTexts[name].firstMatch
        return text.exists ? text : app.buttons[name].firstMatch
    }

    /// The three seeded boards, top to bottom as the sidebar draws them.
    private func orderedBoardNames() -> [String] {
        boards
            .map { ($0.name, row($0.name).frame.minY) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// Sorting lives in View ▸ Sort Boards By, not on the sidebar: a `Menu` inside a `List`
    /// section header is folded into the header's own accessibility element and never opens
    /// from a click on it. The menu bar is both where a Mac user looks and what a test can
    /// drive reliably.
    private func sortBoards(by mode: String) throws {
        // Retried, and every step waits for a real frame: a submenu item queried the instant
        // its parent opens can answer with an infinite origin, which `click()` throws on.
        for attempt in 0..<3 {
            let view = app.menuBars.menuBarItems["View"]
            XCTAssertTrue(view.waitForExistence(timeout: 5), "no View menu")
            view.click()
            let submenu = app.menuItems["Sort Boards By"].firstMatch
            if !drawn(submenu) { app.typeKey(.escape, modifierFlags: []); continue }
            submenu.click()
            // Descended from the submenu, never searched app-wide: "Name" and "Manual" appear
            // under Sort Notes By too, and a global title query picks whichever comes first.
            let item = submenu.menuItems[mode].firstMatch
            if !drawn(item) { app.typeKey(.escape, modifierFlags: []); continue }
            item.click()
            return
        }
        XCTFail("View ▸ Sort Boards By ▸ \(mode) never came up")
    }

    /// Exists, is hittable, and has a frame a click can actually land in.
    private func drawn(_ element: XCUIElement) -> Bool {
        guard element.waitForExistence(timeout: 5) else { return false }
        return poll(timeout: 3) {
            let frame = element.frame
            return element.isHittable && frame.width > 0 && frame.height > 0 && frame.origin.x.isFinite
        }
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

    private func seedBoards() throws {
        let dir = storageRoot.appendingPathComponent("Boards", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let index: [String: Any] = ["boardOrder": boards.map(\.id.uuidString)]
        try JSONSerialization.data(withJSONObject: index).write(to: dir.appendingPathComponent("boards.json"))

        for board in boards {
            let column = UUID().uuidString
            let json: [String: Any] = [
                "id": board.id.uuidString, "name": board.name,
                "created": board.created,
                "extraColumns": [["id": column, "name": "Todo", "isDone": false, "emoji": "📋"]],
                "cards": [],
            ]
            try JSONSerialization.data(withJSONObject: json)
                .write(to: dir.appendingPathComponent("\(board.id.uuidString).json"))
        }
    }
}
