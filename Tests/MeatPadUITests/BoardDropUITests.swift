import XCTest

/// Card reordering is positional now: the column reads the pointer's y and inserts there.
/// Only a real drag can prove that — the arithmetic is unit-tested, the wiring is not.
///
/// Image drops from outside the app are not here: XCUITest has no external drag source, so a
/// Finder or browser image drag cannot be simulated, and faking one would test the fake. The
/// attachment drag-out test below is the exception — its source is a tile inside the app, not
/// an external one, so a real press-drag can drive it.
final class BoardDropUITests: XCTestCase {
    private var app: XCUIApplication!
    private var storageRoot: URL!
    private let boardID = UUID()
    private let columnID = UUID()
    private let secondColumnID = UUID()
    // A dedicated pair in the Doing column for the attachment drag-out test below: card A
    // carries the seeded attachment, card B is the drop target.
    private let cardA = UUID()
    private let cardB = UUID()

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
        XCTAssertTrue(titles.firstMatch.waitForExistence(timeout: 20), "board never rendered")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: storageRoot)
    }

    func testDraggingACardBelowTheLastRowAppendsIt() throws {
        let below = bottom(of: card("Gamma"), plus: 12)
        center(of: card("Alpha")).click(forDuration: 0.4, thenDragTo: below)

        XCTAssertTrue(poll { self.storedOrder() == ["Beta", "Gamma", "Alpha"] },
                      "order is \(storedOrder())")
        XCTAssertEqual(shownOrder(), ["Beta", "Gamma", "Alpha"])
    }

    func testDraggingACardBetweenTwoRowsInsertsThere() throws {
        // Halfway between the two titles: a full-display row is taller than its title (notes
        // sit under it), so "just under Alpha's title" is still above Alpha's midline and
        // would insert at 0. The midpoint is below Alpha's middle and above Beta's.
        let target = between(card("Alpha"), card("Beta"))
        center(of: card("Gamma")).click(forDuration: 0.4, thenDragTo: target)

        XCTAssertTrue(poll { self.storedOrder() == ["Alpha", "Gamma", "Beta"] },
                      "order is \(storedOrder())")
        XCTAssertEqual(shownOrder(), ["Alpha", "Gamma", "Beta"])
    }

    func testDraggingACardToAnotherColumnStillWorks() throws {
        let doing = app.staticTexts["Doing"].firstMatch
        XCTAssertTrue(doing.waitForExistence(timeout: 5))
        center(of: card("Beta")).click(forDuration: 0.4, thenDragTo: bottom(of: doing, plus: 80))

        XCTAssertTrue(poll { self.storedColumn("Beta") == self.secondColumnID.uuidString },
                      "Beta never left its column")
        XCTAssertEqual(storedOrder(), ["Alpha", "Gamma"])
    }

    /// Task 6: a tile drags out as a copy named after its card. Dropping it on another card
    /// must attach the copy there, leave card A's own attachment in place, and leave card A
    /// itself in place — today's press-drag on a tile moves the whole card instead.
    func testDraggingAnAttachmentOntoAnotherCardCopiesItAndLeavesTheSourceCardInPlace() throws {
        let tile = app.descendants(matching: .any)["card.attachment"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "card A never drew its attachment tile")
        let target = card("Card B")

        tile.press(forDuration: 0.3, thenDragTo: target)

        XCTAssertTrue(poll { (self.storedCard(self.cardB)?["attachments"] as? [String])?.count == 1 },
                      "the attachment never landed on card B")
        XCTAssertEqual((storedCard(cardA)?["attachments"] as? [String])?.count, 1,
                       "card A lost its own attachment")
        XCTAssertEqual(storedCardOrder(), [cardA.uuidString, cardB.uuidString],
                       "card A moved instead of staying in place")
    }

    // MARK: - Reading the board

    private var titles: XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "card.title")
    }

    /// An idle row is a `Text` and an editing one a `TextField`, so the title is read from
    /// whichever of value/label the row exposes.
    private func faceText(_ element: XCUIElement) -> String { element.value as? String ?? element.label }

    private func card(_ title: String) -> XCUIElement {
        XCTAssertTrue(titles.firstMatch.waitForExistence(timeout: 5))
        let all = titles.allElementsBoundByIndex
        guard let element = all.first(where: { self.faceText($0) == title }) else {
            XCTFail("no card titled \(title) among \(all.map(faceText))")
            return titles.firstMatch
        }
        return element
    }

    private func center(of element: XCUIElement) -> XCUICoordinate {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    }
    private func between(_ a: XCUIElement, _ b: XCUIElement) -> XCUICoordinate {
        let dy = (b.frame.midY - a.frame.midY) / 2
        return center(of: a).withOffset(CGVector(dx: 0, dy: dy))
    }
    private func bottom(of element: XCUIElement, plus dy: CGFloat) -> XCUICoordinate {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1)).withOffset(CGVector(dx: 0, dy: dy))
    }

    /// What the Todo column actually draws, top to bottom. Read once after a settle: a polling
    /// loop here hands back the cached accessibility snapshot. Filtered to the reorder fixture's
    /// three titles — the Doing column now also carries the attachment-drag fixture's own two
    /// cards, which are not part of what these reorder assertions are about.
    private func shownOrder() -> [String] {
        usleep(1_500_000)
        _ = titles.firstMatch.waitForExistence(timeout: 5)
        return titles.allElementsBoundByIndex
            .sorted { $0.frame.minY < $1.frame.minY }
            .map(faceText)
            .filter { ["Alpha", "Beta", "Gamma"].contains($0) }
    }

    private func boardJSON() -> [String: Any] {
        let url = storageRoot.appendingPathComponent("Boards/\(boardID.uuidString).json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }
    private func storedCards() -> [[String: Any]] { (boardJSON()["cards"] as? [[String: Any]]) ?? [] }
    /// The first column's cards, in stored order — which is the order the column renders.
    private func storedOrder() -> [String] {
        storedCards()
            .filter { $0["columnID"] as? String == columnID.uuidString }
            .compactMap { $0["title"] as? String }
    }
    private func storedColumn(_ title: String) -> String? {
        storedCards().first { $0["title"] as? String == title }?["columnID"] as? String
    }
    /// One card's stored JSON, by id.
    private func storedCard(_ id: UUID) -> [String: Any]? {
        storedCards().first { $0["id"] as? String == id.uuidString }
    }
    /// The Doing column's card ids, in stored order — the column the attachment-drag fixture
    /// below lives in, so "card A did not move" can be checked without pulling in the Todo
    /// column's own cards.
    private func storedCardOrder() -> [String] {
        storedCards()
            .filter { $0["columnID"] as? String == secondColumnID.uuidString }
            .compactMap { $0["id"] as? String }
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
        let index: [String: Any] = [
            "boardOrder": [boardID.uuidString],
            "globalColumns": [
                ["id": columnID.uuidString, "name": "Todo", "isDone": false, "emoji": "📋"],
                ["id": secondColumnID.uuidString, "name": "Doing", "isDone": false, "emoji": "🚧"],
            ],
        ]
        try JSONSerialization.data(withJSONObject: index).write(to: boards.appendingPathComponent("boards.json"))
        let stamp = "2026-09-03T09:00:00Z"
        let cards = ["Alpha", "Beta", "Gamma"].map { title in
            [
                "id": UUID().uuidString, "title": title,
                "columnID": columnID.uuidString, "created": stamp, "modified": stamp,
            ]
        }
        // Two more cards in the Doing column, for the attachment drag-out test: card A carries
        // the seeded attachment, card B is the drop target.
        let dragCards: [[String: Any]] = [
            ["id": cardA.uuidString, "title": "Card A", "columnID": secondColumnID.uuidString,
             "created": stamp, "modified": stamp, "attachments": ["seed.png"]],
            ["id": cardB.uuidString, "title": "Card B", "columnID": secondColumnID.uuidString,
             "created": stamp, "modified": stamp],
        ]
        let board: [String: Any] = [
            "id": boardID.uuidString, "name": "Test Board", "extraColumns": [], "cards": cards + dragCards,
        ]
        try JSONSerialization.data(withJSONObject: board).write(to: boards.appendingPathComponent("\(boardID.uuidString).json"))

        // The file has to exist too, or the tile draws nothing to grab a drag from.
        let attachments = boards.appendingPathComponent("Attachments/\(cardA.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try Self.onePixelPNG.write(to: attachments.appendingPathComponent("seed.png"))
    }

    /// A 1×1 red PNG — the smallest thing `CGImageSource` will make a thumbnail out of.
    private static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==")!
}
