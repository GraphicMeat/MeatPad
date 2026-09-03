import XCTest

/// Card labels end to end: create one from the filter field, hang it on a card, and prove the
/// filter actually removes the cards that don't carry it. None of this is reachable from
/// MeatPadKit — the store is unit-tested; what breaks in practice is the AppKit half.
///
/// Each test runs against a throwaway storage root seeded on disk in `setUp`, so it never
/// touches real notes or boards, and launches straight onto the board with
/// `-meatpad.revealBoard <uuid>` — no clicking to get there.
final class BoardLabelUITests: XCTestCase {

    private var app: XCUIApplication!
    private var storageRoot: URL!
    private let boardID = UUID()
    private let columnID = UUID()
    private let otherBoardID = UUID()

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
        XCTAssertTrue(cardTitles.firstMatch.waitForExistence(timeout: 20), "board never rendered")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: storageRoot)
    }

    // MARK: - Tests

    func testCreatingALabelFromTheFilterFieldAddsAChip() throws {
        createLabel("Bug")
        XCTAssertTrue(element("labelFilter.chip.Bug").waitForExistence(timeout: 5))
    }

    func testFilteringShowsOnlyTheCardsCarryingTheLabel() throws {
        createLabel("Bug")
        clearFilter()
        assign(label: "Bug", toCardTitled: "Alpha")

        filter(by: "Bug")

        XCTAssertTrue(waitForCardTitles(["Alpha"]), "visible cards: \(visibleCardTitles)")
    }

    func testClearingTheFilterBringsEveryCardBack() throws {
        createLabel("Bug")
        clearFilter()
        assign(label: "Bug", toCardTitled: "Alpha")
        filter(by: "Bug")
        XCTAssertTrue(waitForCardTitles(["Alpha"]))

        element("labelFilter.clear").click()

        XCTAssertTrue(waitForCardTitles(["Alpha", "Beta"]), "visible cards: \(visibleCardTitles)")
    }

    func testClickingAChipRemovesThatLabelFromTheFilter() throws {
        createLabel("Bug")
        clearFilter()
        assign(label: "Bug", toCardTitled: "Alpha")
        filter(by: "Bug")
        XCTAssertTrue(waitForCardTitles(["Alpha"]))

        element("labelFilter.chip.Bug").click()

        XCTAssertTrue(waitForCardTitles(["Alpha", "Beta"]), "visible cards: \(visibleCardTitles)")
    }

    func testUnlabelledCardsAreHiddenByAFilterNobodyCarries() throws {
        createLabel("Sunday")

        XCTAssertTrue(waitForCardTitles([]), "visible cards: \(visibleCardTitles)")
    }

    func testCreatingALabelFromACardMenuAssignsItToThatCard() throws {
        openNewLabelForm(onCardTitled: "Alpha")

        let field = element("newLabel.name")
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the New Label form has no name field")
        field.click()
        field.typeText("FromCard")
        element("newLabel.create").click()
        closeEditor()

        XCTAssertTrue(app.staticTexts["FromCard"].waitForExistence(timeout: 5),
                      "the new label never landed on the card")
    }

    /// The colour is the point of the form: picking a swatch has to survive into the label,
    /// not just tick a circle. Read back through the filter row, the one place a label's
    /// colour is rendered as a control instead of as paint.
    func testTheNewLabelFormPicksAColour() throws {
        openNewLabelForm(onCardTitled: "Alpha")

        let field = element("newLabel.name")
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the New Label form has no name field")
        field.click()
        field.typeText("Coloured")
        let swatch = element("newLabel.swatch.4")
        XCTAssertTrue(swatch.exists, "the New Label form offers no colours")
        swatch.click()
        XCTAssertTrue(element("newLabel.swatch.4").isSelected, "the picked swatch never took")
        element("newLabel.create").click()

        closeEditor()
        XCTAssertTrue(app.staticTexts["Coloured"].waitForExistence(timeout: 5),
                      "the new label never landed on the card")
        // Read back what the app actually wrote: a swatch that only highlights itself is a
        // colour picker that picks nothing.
        XCTAssertEqual(try storedColor(ofLabel: "Coloured"), Self.palette[4],
                       "the label was not stored in the picked colour")
    }

    /// The All Boards overview stacks four boards into one column; every card has to say
    /// which board it came from.
    func testAllBoardsBadgesEveryCardWithItsBoard() throws {
        showAllBoards()
        let badges = app.descendants(matching: .any).matching(identifier: "card.boardBadge")
        XCTAssertTrue(badges.firstMatch.waitForExistence(timeout: 5), "no board badges in All Boards")
        XCTAssertEqual(badges.count, 3, "every card in All Boards carries a badge")
    }

    // MARK: - Board actions

    /// Relaunches onto the overview — `setUp` lands on one board, which shows no badges.
    private func showAllBoards() {
        app.terminate()
        app.launchArguments = [
            "-meatpad.storageRootOverride", storageRoot.path,
            "-meatpad.revealBoard", "all",
            "-hasSeenFirstRunIntro", "YES",
        ]
        app.launch()
        XCTAssertTrue(cardTitles.firstMatch.waitForExistence(timeout: 20), "All Boards never rendered")
    }

    /// Opens the filter popover, types the name, and commits with Return — the create-on-⏎
    /// path. A created label is filtered on immediately, so the board narrows straight away.
    private func createLabel(_ name: String) {
        element("board.labelFilter").click()
        let search = element("labelFilter.search")
        XCTAssertTrue(search.waitForExistence(timeout: 5), "filter popover never opened")
        search.click()
        search.typeText(name)
        XCTAssertTrue(element("labelFilter.create").waitForExistence(timeout: 5),
                      "no create row for “\(name)”")
        search.typeKey(.return, modifierFlags: [])
        dismissPopover()
    }

    /// Ticks the label in the card editor's label menu, then closes the editor.
    private func assign(label: String, toCardTitled title: String) {
        let card = cardTitles.matching(NSPredicate(format: "value == %@", title)).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5), "no card titled “\(title)”")
        openLabelMenu(onCardTitled: title)
        let item = app.menuItems[label]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the label menu has no “\(label)”")
        item.click()
        closeEditor()
    }

    /// Card ⋯ → the editor's label menu → New Label…
    private func openNewLabelForm(onCardTitled title: String) {
        openLabelMenu(onCardTitled: title)
        let new = app.menuItems["New Label…"]
        XCTAssertTrue(new.waitForExistence(timeout: 5), "the label menu has no New Label item")
        new.click()
    }

    /// The ⋯ button opens the card editor; labels hang off its own menu inside.
    private func openLabelMenu(onCardTitled title: String) {
        let more = app.descendants(matching: .any).matching(identifier: "card.actions")
            .element(boundBy: cardIndex(of: title))
        more.click()
        let labels = element("cardEditor.labels")
        XCTAssertTrue(labels.waitForExistence(timeout: 5), "the card editor never opened")
        labels.click()
    }

    /// The editor is a popover, and it is modal to the keyboard while it is up. Escape only
    /// reaches it once something inside holds the keyboard, so click a field first.
    private func closeEditor() {
        guard element("cardEditor.title").exists else { return }
        element("cardEditor.title").click()
        app.typeKey(.escape, modifierFlags: [])
        let deadline = Date().addingTimeInterval(5)
        while element("cardEditor.title").exists, Date() < deadline { usleep(200_000) }
    }

    private func filter(by label: String) {
        element("board.labelFilter").click()
        let row = element("labelFilter.row.\(label)")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no dropdown row for “\(label)”")
        row.click()
        dismissPopover()
    }

    private func clearFilter() {
        let clear = element("labelFilter.clear")
        if clear.exists { clear.click() }
    }

    /// The popover is modal to the keyboard; Escape returns the board to the tests. Waited
    /// out rather than fired and forgotten — the next click is eaten by a popover that is
    /// still closing.
    private func dismissPopover() {
        guard element("labelFilter.search").exists else { return }
        app.typeKey(.escape, modifierFlags: [])
        let deadline = Date().addingTimeInterval(5)
        while element("labelFilter.search").exists, Date() < deadline { usleep(200_000) }
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

    /// Polls rather than asserting once: the filter animates, and a card leaves the tree a
    /// frame or two after the click.
    private func waitForCardTitles(_ expected: [String]) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if visibleCardTitles == expected.sorted() { return true }
            usleep(200_000)
        }
        return false
    }

    private func cardIndex(of title: String) -> Int {
        visibleCardTitles.firstIndex(of: title) ?? 0
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    // MARK: - Reading what the app wrote

    /// `CardLabel.palette`, which the UI test bundle cannot import (it links the app, not
    /// MeatPadKit). Kept in the same order — a swatch index means nothing otherwise.
    private static let palette = [
        "#E5484D", "#F76B15", "#FFB224", "#99D52A", "#30A46C", "#12A594",
        "#00A2C7", "#3E63DD", "#7C66DC", "#BF7AF0", "#E93D82", "#AD7F58",
    ]

    /// Polls the index file the app writes, and returns the label's colour as a hex string.
    private func storedColor(ofLabel name: String) throws -> String {
        let url = storageRoot.appendingPathComponent("Boards/boards.json")
        let deadline = Date().addingTimeInterval(5)
        var last = ""
        repeat {
            if let data = try? Data(contentsOf: url),
               let index = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let labels = index["labels"] as? [[String: Any]],
               let label = labels.first(where: { $0["name"] as? String == name }),
               let color = label["color"] as? [String: Double] {
                last = Self.hex(color)
                return last
            }
            usleep(200_000)
        } while Date() < deadline
        return last
    }

    private static func hex(_ color: [String: Double]) -> String {
        let channel = { (key: String) in Int(((color[key] ?? 0) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channel("r"), channel("g"), channel("b"))
    }

    // MARK: - Seeding

    /// Writes the same files `BoardStore` would: `Boards/boards.json` plus one board file.
    /// Two cards, one column — enough for "one matches, one doesn't".
    private func seedBoard() throws {
        let boards = storageRoot.appendingPathComponent("Boards", isDirectory: true)
        try FileManager.default.createDirectory(at: boards, withIntermediateDirectories: true)

        let index: [String: Any] = [
            "boardOrder": [boardID.uuidString, otherBoardID.uuidString],
            "globalColumns": [
                ["id": columnID.uuidString, "name": "Todo", "isDone": false, "emoji": "📋"],
            ],
        ]
        try JSONSerialization.data(withJSONObject: index)
            .write(to: boards.appendingPathComponent("boards.json"))

        let stamp = "2026-08-24T09:00:00Z"
        let board: [String: Any] = [
            "id": boardID.uuidString,
            "name": "Test Board",
            "extraColumns": [],
            "cards": ["Alpha", "Beta"].map { title in
                [
                    "id": UUID().uuidString,
                    "title": title,
                    "columnID": columnID.uuidString,
                    "created": stamp,
                    "modified": stamp,
                ]
            },
        ]
        try JSONSerialization.data(withJSONObject: board)
            .write(to: boards.appendingPathComponent("\(boardID.uuidString).json"))

        // A second board so the All Boards overview has two badges to tell apart.
        let other: [String: Any] = [
            "id": otherBoardID.uuidString,
            "name": "Other Board",
            "extraColumns": [],
            "cards": [[
                "id": UUID().uuidString,
                "title": "Gamma",
                "columnID": columnID.uuidString,
                "created": stamp,
                "modified": stamp,
            ]],
        ]
        try JSONSerialization.data(withJSONObject: other)
            .write(to: boards.appendingPathComponent("\(otherBoardID.uuidString).json"))
    }
}
