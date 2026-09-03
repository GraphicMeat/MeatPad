import XCTest

/// The card editor — the popup behind a card's ⋯. Everything here is AppKit-shaped: a
/// popover that has to open, take edits, write them through to disk, and let a long title
/// wrap instead of clipping it. None of that is visible to the store's own tests.
final class BoardCardEditorUITests: XCTestCase {

    private var app: XCUIApplication!
    private var storageRoot: URL!
    private let boardID = UUID()
    private let columnID = UUID()

    /// Long enough to need three lines in a 280pt column — the card in the bug report read
    /// "Masazas E…" and had to be opened to identify.
    private static let longTitle = "Quarterly infrastructure review with the whole platform team and stakeholders"

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

    // MARK: - Opening

    func testMoreButtonOpensTheEditorOnThatCard() throws {
        openEditor(onCardTitled: "Alpha")

        XCTAssertTrue(element("cardEditor.title").waitForExistence(timeout: 5), "⋯ opened no editor")
        XCTAssertEqual(element("cardEditor.title").value as? String, "Alpha",
                       "the editor opened on the wrong card")
    }

    /// The reason the redesign exists: the editor is a page of rows, not a list of verbs.
    /// Attached as an image so the layout can be signed off without a pair of eyes on the Mac.
    func testEditorLayout() throws {
        // Colour one card first: the shot has to show what a coloured cell looks like on the
        // board, not just the swatches inside the editor.
        openEditor(onCardTitled: "Alpha")
        XCTAssertTrue(element("cardEditor.color.8").waitForExistence(timeout: 5))
        element("cardEditor.color.8").click()
        closeEditor()

        openEditor(onCardTitled: Self.longTitle)
        XCTAssertTrue(element("cardEditor.title").waitForExistence(timeout: 5))
        for id in ["cardEditor.title", "cardEditor.labels", "cardEditor.due",
                   "cardEditor.notes", "cardEditor.delete", "cardEditor.color.none"] {
            XCTAssertTrue(element(id).exists, "the editor has no \(id)")
        }

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "card-editor"
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - Colour

    func testPickingAColourPaintsTheCardAndIsStored() throws {
        openEditor(onCardTitled: "Alpha")
        let swatch = element("cardEditor.color.4")
        XCTAssertTrue(swatch.waitForExistence(timeout: 5), "the editor offers no colours")
        swatch.click()

        XCTAssertTrue(element("cardEditor.color.4").isSelected, "the picked swatch never took")
        XCTAssertEqual(try storedColor(ofCardTitled: "Alpha"), Self.palette[4],
                       "the colour never reached the card")
    }

    func testClearingTheColourPutsTheCardBackToPlain() throws {
        openEditor(onCardTitled: "Alpha")
        element("cardEditor.color.4").click()
        XCTAssertEqual(try storedColor(ofCardTitled: "Alpha"), Self.palette[4])

        element("cardEditor.color.none").click()

        XCTAssertNil(try waitForStoredColor(ofCardTitled: "Alpha", toBe: nil),
                     "the card kept its colour")
    }

    // MARK: - Editing

    func testEditingTheTitleInTheEditorWritesThroughToTheCard() throws {
        openEditor(onCardTitled: "Alpha")
        let field = element("cardEditor.title")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Renamed")
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(waitForCardTitle("Renamed"), "visible cards: \(visibleCardTitles)")
    }

    func testNotesTypedInTheEditorLandOnTheCard() throws {
        openEditor(onCardTitled: "Alpha")
        let notes = element("cardEditor.notes")
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        notes.click()
        notes.typeText("from the editor")
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertEqual(try waitForStoredBody(ofCardTitled: "Alpha"), "from the editor")
    }

    func testAddingADateFromTheEditorSetsOneOnTheCard() throws {
        openEditor(onCardTitled: "Alpha")
        let due = element("cardEditor.due")
        XCTAssertTrue(due.waitForExistence(timeout: 5))
        due.click()

        XCTAssertTrue(try waitForStoredDue(ofCardTitled: "Alpha"), "no due date was written")
        // The picker expands inside the popover, which has to grow to hold it — a popover
        // that measured itself before the disclosure opened would clip the calendar.
        XCTAssertTrue(element("cardEditor.datePicker").waitForExistence(timeout: 5),
                      "the date picker never opened")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "card-editor-date"
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - Title wrapping

    /// A truncated title is what sent us here. Measured, not eyeballed: a wrapped title is
    /// taller than a single line of the same font.
    func testALongTitleWrapsOntoMoreThanOneLine() throws {
        let short = card(titled: "Alpha")
        let long = card(titled: Self.longTitle)
        XCTAssertTrue(long.exists, "the long-titled card never rendered")
        XCTAssertGreaterThan(long.frame.height, short.frame.height * 1.8,
                             "the long title did not wrap (short: \(short.frame.height), long: \(long.frame.height))")
    }

    /// The editor's own title has to wrap too — it is the widest, boldest text in the app,
    /// and a popup opened to read a long title that clips it is worse than useless.
    func testALongTitleWrapsInTheEditorToo() throws {
        openEditor(onCardTitled: "Alpha")
        let short = element("cardEditor.title")
        XCTAssertTrue(short.waitForExistence(timeout: 5))
        let oneLine = short.frame.height
        closeEditor()

        openEditor(onCardTitled: Self.longTitle)
        let long = element("cardEditor.title")
        XCTAssertTrue(long.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(long.frame.height, oneLine * 1.8,
                             "the editor clipped the title (one line: \(oneLine), long: \(long.frame.height))")
    }

    // MARK: - Driving the editor

    /// Escape only reaches the popover once something inside it holds the keyboard, and the
    /// popover leaves the tree a beat later — opening the next one before it is gone just
    /// dismisses this one.
    private func closeEditor() {
        element("cardEditor.title").click()
        app.typeKey(.escape, modifierFlags: [])
        let deadline = Date().addingTimeInterval(5)
        while element("cardEditor.title").exists, Date() < deadline { usleep(200_000) }
        XCTAssertFalse(element("cardEditor.title").exists, "the editor would not close")
    }

    private func openEditor(onCardTitled title: String) {
        let more = app.descendants(matching: .any).matching(identifier: "card.actions")
            .element(boundBy: cardIndex(of: title))
        XCTAssertTrue(more.waitForExistence(timeout: 5), "no ⋯ for “\(title)”")
        more.click()
    }

    // MARK: - Reading the board

    /// `card.title` is a `Text` until the row is clicked and a `TextField` after, so the query
    /// can't name an element type. Its text is the value either way — bar an idle row exposed
    /// as a button, which carries it as the label instead.
    private var cardTitles: XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "card.title")
    }

    private func card(titled title: String) -> XCUIElement {
        cardTitles.element(boundBy: cardIndex(of: title))
    }

    private var visibleCardTitles: [String] {
        (0..<cardTitles.count)
            .map { cardTitles.element(boundBy: $0) }
            .map { $0.value as? String ?? $0.label }
            .sorted()
    }

    private func cardIndex(of title: String) -> Int {
        visibleCardTitles.firstIndex(of: title) ?? 0
    }

    private func waitForCardTitle(_ title: String) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if visibleCardTitles.contains(title) { return true }
            usleep(200_000)
        }
        return false
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

    private func storedCard(titled title: String) -> [String: Any]? {
        let url = storageRoot.appendingPathComponent("Boards/\(boardID.uuidString).json")
        guard let data = try? Data(contentsOf: url),
              let board = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cards = board["cards"] as? [[String: Any]]
        else { return nil }
        return cards.first { $0["title"] as? String == title }
    }

    private func storedColor(ofCardTitled title: String) throws -> String? {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if let color = storedCard(titled: title)?["color"] as? [String: Double] {
                return Self.hex(color)
            }
            usleep(200_000)
        } while Date() < deadline
        return nil
    }

    /// Polls for the colour to become `expected` — clearing writes the file a beat after the
    /// click, and asserting once reads the colour that is on its way out.
    @discardableResult
    private func waitForStoredColor(ofCardTitled title: String, toBe expected: String?) throws -> String? {
        let deadline = Date().addingTimeInterval(5)
        var last: String?
        repeat {
            last = (storedCard(titled: title)?["color"] as? [String: Double]).map(Self.hex)
            if last == expected { return last }
            usleep(200_000)
        } while Date() < deadline
        return last
    }

    private func waitForStoredBody(ofCardTitled title: String) throws -> String? {
        let deadline = Date().addingTimeInterval(8)
        var last: String?
        repeat {
            last = storedCard(titled: title)?["body"] as? String
            if last?.isEmpty == false { return last }
            usleep(200_000)
        } while Date() < deadline
        return last
    }

    private func waitForStoredDue(ofCardTitled title: String) throws -> Bool {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if storedCard(titled: title)?["due"] != nil { return true }
            usleep(200_000)
        } while Date() < deadline
        return false
    }

    private static func hex(_ color: [String: Double]) -> String {
        let channel = { (key: String) in Int(((color[key] ?? 0) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channel("r"), channel("g"), channel("b"))
    }

    // MARK: - Seeding

    /// The same files `BoardStore` writes: one board, one column, a short card and a card
    /// whose title cannot fit on one line.
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
        let board: [String: Any] = [
            "id": boardID.uuidString,
            "name": "Test Board",
            "extraColumns": [],
            "cards": ["Alpha", Self.longTitle].map { title in
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
    }
}
