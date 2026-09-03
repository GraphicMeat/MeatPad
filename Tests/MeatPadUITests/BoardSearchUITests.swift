import XCTest

/// The board's card search end to end: type into the field, watch the cards that don't
/// contain the text leave. MeatPadKit unit-tests the matcher itself; what it cannot reach is
/// whether the field is wired to the columns at all — the half of this feature that has
/// historically broken on this board.
///
/// Each run gets its own storage root, seeded on disk before launch and thrown away after,
/// and launches straight onto the board with `-meatpad.revealBoard <uuid>`.
final class BoardSearchUITests: XCTestCase {

    private var app: XCUIApplication!
    private var storageRoot = URL(fileURLWithPath: "/")
    private var boardID = UUID()
    private var columnID = UUID()

    override func setUpWithError() throws {
        continueAfterFailure = false
        storageRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MeatPadUITests-\(UUID().uuidString)", isDirectory: true)
        boardID = UUID()
        columnID = UUID()
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

    func testTypingFiltersOutTheCardsThatDoNotContainTheText() {
        search("beta")

        XCTAssertTrue(waitForCardTitles(["Beta"]), "visible cards: \(visibleCardTitles)")
    }

    /// Case is not part of what the user typed — "beta" has to find "Beta", and a mid-word
    /// substring has to count. Both are `localizedStandardContains`, not a prefix test.
    func testSearchIsCaseInsensitiveAndMatchesMidWord() {
        search("LPH")

        XCTAssertTrue(waitForCardTitles(["Alpha"]), "visible cards: \(visibleCardTitles)")
    }

    /// The body is the half you cannot see on the card face — searching it is the reason to
    /// have a search rather than squint at the column.
    func testSearchMatchesTheCardBodyNotJustTheTitle() {
        search("notarization")

        XCTAssertTrue(waitForCardTitles(["Alpha"]), "visible cards: \(visibleCardTitles)")
    }

    func testNoMatchesEmptiesTheColumn() {
        search("zzz")

        XCTAssertTrue(waitForCardTitles([]), "visible cards: \(visibleCardTitles)")
    }

    func testClearingTheSearchBringsEveryCardBack() {
        search("beta")
        XCTAssertTrue(waitForCardTitles(["Beta"]))

        let field = searchField
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])

        XCTAssertTrue(waitForCardTitles(["Alpha", "Beta"]), "visible cards: \(visibleCardTitles)")
    }

    // MARK: - Driving the board

    private var searchField: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "board.search").firstMatch
    }

    private func search(_ text: String) {
        let field = searchField
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the board has no search field")
        field.click()
        field.typeText(text)
    }

    // MARK: - Reading the board

    /// `card.title` is a `Text` until the row is clicked and a `TextField` after, so the query
    /// can't name an element type. Its text is the value either way — bar an idle row exposed
    /// as a button, which carries it as the label instead.
    private var cardTitles: XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "card.title")
    }

    private var visibleCardTitles: [String] {
        (0..<cardTitles.count)
            .map { cardTitles.element(boundBy: $0) }
            .map { $0.value as? String ?? $0.label }
            .sorted()
    }

    /// Polls rather than asserting once: cards leave the tree a frame or two after the
    /// keystroke that filtered them out.
    private func waitForCardTitles(_ expected: [String]) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if visibleCardTitles == expected.sorted() { return true }
            usleep(200_000)
        }
        return false
    }

    // MARK: - Seeding

    /// Writes the same files `BoardStore` would: `Boards/boards.json` plus one board file.
    /// Two cards in one column, one of them carrying a body no title contains — enough for
    /// "one matches, one doesn't" on both fields.
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

        let stamp = "2026-08-24T09:00:00Z"
        let cards: [[String: Any]] = [
            [
                "id": UUID().uuidString,
                "title": "Alpha",
                "body": "blocked on notarization",
                "columnID": columnID.uuidString,
                "created": stamp,
                "modified": stamp,
            ],
            [
                "id": UUID().uuidString,
                "title": "Beta",
                "columnID": columnID.uuidString,
                "created": stamp,
                "modified": stamp,
            ],
        ]
        let board: [String: Any] = [
            "id": boardID.uuidString,
            "name": "Test Board",
            "extraColumns": [],
            "cards": cards,
        ]
        try JSONSerialization.data(withJSONObject: board)
            .write(to: boards.appendingPathComponent("\(boardID.uuidString).json"))
    }
}
