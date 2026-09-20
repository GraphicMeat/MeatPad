import XCTest

/// The All Boards overview's combined column: columns picked from individual boards pool into
/// one displayed column. The rule that matters and that no unit test can see is the de-dup —
/// a merged column's cards render in Combined and NOWHERE else, not in the pooled default
/// column they would otherwise fall into and not in "Other".
///
/// Two boards are seeded. Each has a Todo carrying the fixed template id (so the overview
/// pools them) plus an extra column of its own (which the overview would otherwise dump into
/// "Other").
final class BoardCombinedColumnUITests: XCTestCase {

    private var app: XCUIApplication!
    private var storageRoot = URL(fileURLWithPath: "/")
    private var alphaBoard = UUID()
    private var betaBoard = UUID()
    private var alphaExtra = UUID()
    private var betaExtra = UUID()
    /// `BoardStore.todoID` — fixed, and shared by every board's copy of Todo. That sharing is
    /// exactly why the merge selection is keyed by the (board, column) PAIR.
    private let todoID = UUID(uuidString: "5D091EAF-B0A5-4000-8000-000000000001")!

    override func setUpWithError() throws {
        continueAfterFailure = false
        storageRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MeatPadUITests-\(UUID().uuidString)", isDirectory: true)
        alphaBoard = UUID()
        betaBoard = UUID()
        alphaExtra = UUID()
        betaExtra = UUID()
        try seedBoards()

        app = XCUIApplication()
        app.launchArguments = [
            "-meatpad.storageRootOverride", storageRoot.path,
            "-meatpad.revealBoard", "all",
            "-hasSeenFirstRunIntro", "YES",
        ]
        app.launch()
        XCTAssertTrue(combineButton.waitForExistence(timeout: 20),
                      "the All Boards overview never rendered its combine menu")
        // The picks are remembered across launches, so a previous run's would decide what this
        // one sees. NOT cleared with a launch argument: an argument lands in NSArgumentDomain,
        // which overrides every *read* of that key — the app would write the toggle and then
        // keep reading the empty argument back, and nothing on screen would ever change.
        try tapCombineMenu(then: "Clear")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: storageRoot)
    }

    // MARK: - Tests

    /// Nothing picked: the overview is what it always was — no Combined column at all.
    func testNoCombinedColumnUntilSomethingIsPicked() {
        XCTAssertFalse(app.staticTexts["Combined"].exists, "an empty selection still drew a Combined column")
    }

    func testPickingTwoBoardsExtraColumnsPoolsTheirCards() throws {
        try merge(board: alphaBoard, column: alphaExtra)
        try merge(board: betaBoard, column: betaExtra)

        XCTAssertTrue(app.staticTexts["Combined"].waitForExistence(timeout: 5), "no Combined column")
        XCTAssertTrue(poll { self.titles(containing: "Alpha extra") == 1 },
                      "Alpha's extra card appears \(titles(containing: "Alpha extra")) times, not once")
        XCTAssertTrue(poll { self.titles(containing: "Beta extra") == 1 },
                      "Beta's extra card appears \(titles(containing: "Beta extra")) times, not once")
    }

    /// The de-dup rule: a merged Todo's cards leave the pooled Todo column entirely. The other
    /// board's Todo, which was not picked, keeps its card there.
    func testAMergedDefaultColumnLeavesThePooledOneAndTakesOnlyItsOwnBoard() throws {
        try merge(board: alphaBoard, column: todoID)

        XCTAssertTrue(app.staticTexts["Combined"].waitForExistence(timeout: 5), "no Combined column")
        XCTAssertTrue(poll { self.titles(containing: "Alpha todo") == 1 },
                      "Alpha's todo card is drawn \(titles(containing: "Alpha todo")) times")
        XCTAssertTrue(poll { self.titles(containing: "Beta todo") == 1 },
                      "picking Alpha's Todo disturbed Beta's, which shares the same column id")
    }

    func testTheSelectionSurvivesARelaunch() throws {
        try merge(board: alphaBoard, column: alphaExtra)
        XCTAssertTrue(app.staticTexts["Combined"].waitForExistence(timeout: 5))

        app.terminate()
        // Relaunch without the clearing argument — NSArgumentDomain would otherwise override
        // the value the app just wrote.
        app.launchArguments = [
            "-meatpad.storageRootOverride", storageRoot.path,
            "-meatpad.revealBoard", "all",
            "-hasSeenFirstRunIntro", "YES",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["Combined"].waitForExistence(timeout: 20),
                      "the combined column did not come back")
    }

    func testClearPutsEveryCardBackWhereItWas() throws {
        try merge(board: alphaBoard, column: alphaExtra)
        XCTAssertTrue(app.staticTexts["Combined"].waitForExistence(timeout: 5))

        try tapCombineMenu(then: "Clear")

        XCTAssertTrue(poll { !app.staticTexts["Combined"].exists }, "Clear left the Combined column up")
        XCTAssertTrue(poll { self.titles(containing: "Alpha extra") == 1 },
                      "Alpha's extra card went missing after Clear")
    }

    // MARK: - Driving the menu

    /// How many card faces carry `needle`. One is right; two means the de-dup failed.
    private func titles(containing needle: String) -> Int {
        app.descendants(matching: .any).matching(identifier: "card.title")
            .allElementsBoundByIndex
            .filter { ($0.value as? String ?? $0.label).contains(needle) }
            .count
    }

    /// A SwiftUI `Menu` lands as a pop-up/menu-button rather than an `app.buttons` element,
    /// so it has to be matched by identifier across every element type.
    private var combineButton: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "board.combine").firstMatch
    }

    private func merge(board: UUID, column: UUID) throws {
        try tapCombineMenu(then: nil, toggling: "board.combine.\(board.uuidString).\(column.uuidString)")
    }

    /// The combine menu, retried: a menu occasionally does not come up on the first click
    /// after the window takes focus, and an opened-but-empty menu swallows the next one.
    private func tapCombineMenu(then item: String?, toggling identifier: String? = nil) throws {
        let button = combineButton
        XCTAssertTrue(button.waitForExistence(timeout: 5), "no combine menu")
        for _ in 0..<3 {
            button.click()
            if let item {
                let entry = app.menuItems[item].firstMatch
                if entry.waitForExistence(timeout: 3) {
                    // Clear is disabled when nothing is picked, which is the normal case in
                    // setUp — the menu still has to be dismissed either way.
                    if entry.isEnabled { entry.click() } else { app.typeKey(.escape, modifierFlags: []) }
                    return
                }
            } else if let identifier {
                let entry = app.menuItems.matching(identifier: identifier).firstMatch
                if entry.waitForExistence(timeout: 3) { entry.click(); return }
            }
            app.typeKey(.escape, modifierFlags: [])
        }
        print("COMBINE MENU TREE >>>\n\(app.debugDescription)\n<<< COMBINE MENU TREE")
        XCTFail("the combine menu never offered \(item ?? identifier ?? "")")
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
        let boards = storageRoot.appendingPathComponent("Boards", isDirectory: true)
        try FileManager.default.createDirectory(at: boards, withIntermediateDirectories: true)
        let index: [String: Any] = ["boardOrder": [alphaBoard.uuidString, betaBoard.uuidString]]
        try JSONSerialization.data(withJSONObject: index).write(to: boards.appendingPathComponent("boards.json"))

        let stamp = "2026-09-20T09:00:00Z"
        for (id, name, extra, prefix) in [
            (alphaBoard, "Alpha", alphaExtra, "Alpha"),
            (betaBoard, "Beta", betaExtra, "Beta"),
        ] {
            let board: [String: Any] = [
                "id": id.uuidString, "name": name,
                "extraColumns": [
                    ["id": todoID.uuidString, "name": "Todo", "isDone": false, "emoji": "📋"],
                    ["id": extra.uuidString, "name": "\(name) Features", "isDone": false],
                ],
                "cards": [
                    ["id": UUID().uuidString, "title": "\(prefix) todo", "columnID": todoID.uuidString,
                     "created": stamp, "modified": stamp],
                    ["id": UUID().uuidString, "title": "\(prefix) extra", "columnID": extra.uuidString,
                     "created": stamp, "modified": stamp],
                ],
            ]
            try JSONSerialization.data(withJSONObject: board)
                .write(to: boards.appendingPathComponent("\(id.uuidString).json"))
        }
    }
}
