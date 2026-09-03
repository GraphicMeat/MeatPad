import XCTest

/// The card display control: three densities, applied to every card on the board at once.
/// None of this is testable below the UI — what the setting changes is layout (how much of the
/// notes the row shows, how many lines is the title allowed), and layout only exists once
/// AppKit has laid it out.
///
/// Seeded like `BoardLabelUITests`: a throwaway storage root, launched straight onto the board.
/// The card carries a title long enough to wrap in a 280pt column and a body, because a short
/// title and an empty card look identical in all three modes.
final class BoardCardDisplayUITests: XCTestCase {

    private var app: XCUIApplication!
    private var storageRoot: URL!
    private let boardID = UUID()
    private let columnID = UUID()

    private let longTitle = "A card title long enough that it has to wrap onto several lines"
    /// Two lines on purpose: a folded notes row still shows the first one, so the second is
    /// the only thing that says whether the notes are open.
    private let notes = "Notes body that only the full display opens\nand a second line under it"

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
        XCTAssertTrue(cardTitle.waitForExistence(timeout: 20), "board never rendered")
    }

    override func tearDownWithError() throws {
        // The setting is a real preference, remembered across launches — put it back, so a test
        // run doesn't quietly re-fold the boards of whoever ran it.
        select(.full)
        app?.terminate()
        try? FileManager.default.removeItem(at: storageRoot)
    }

    // MARK: - Tests

    func testFullOpensTheNotes() throws {
        select(.full)

        XCTAssertTrue(waitForNotes(open: true), "full display left the notes folded")
    }

    func testCompactFoldsTheNotesAway() throws {
        select(.full)
        XCTAssertTrue(waitForNotes(open: true))

        select(.compact)

        XCTAssertTrue(waitForNotes(open: false), "compact left the notes open")
    }

    func testTitlesKeepsTheNotesShut() throws {
        select(.full)
        XCTAssertTrue(waitForNotes(open: true))

        select(.titles)

        XCTAssertTrue(waitForNotes(open: false), "the titles display left the notes open")
    }

    /// The half the notes field can't prove: compact clips the title to one line and the other
    /// two let it wrap. Measured, because "one line" is a height, not an element.
    ///
    /// Ends where it started on purpose: the switch that used to break is the way back down —
    /// a title that grew and stayed wrapped in a display that is meant to clip it.
    func testCompactClipsTheTitleAndTheOthersLetItWrap() throws {
        select(.compact)
        let clipped = settledTitleHeight()

        select(.titles)
        let wrapped = settledTitleHeight()
        XCTAssertGreaterThan(wrapped, clipped * 1.5,
                             "the titles display clipped the title like compact does")

        select(.full)
        XCTAssertEqual(settledTitleHeight(), wrapped, accuracy: 1,
                       "full and titles disagree about how tall a wrapped title is")

        select(.compact)
        XCTAssertEqual(settledTitleHeight(), clipped, accuracy: 1,
                       "the title stayed wrapped after folding back to compact")
    }

    // MARK: - Driving the control

    private enum Display: String {
        case compact = "Compact"
        case titles = "Titles"
        case full = "Full"
    }

    private func select(_ display: Display) {
        let segment = app.radioButtons[display.rawValue]
        guard segment.waitForExistence(timeout: 5) else {
            XCTFail("no “\(display.rawValue)” segment in the card display control")
            return
        }
        segment.click()
    }

    // MARK: - Reading the board

    /// Both rows are a `Text` until they are clicked and a `TextField` after, so neither can
    /// be asked for by element type. The text is the value either way — bar an idle row
    /// exposed as a button, which carries it as the label.
    private var cardTitle: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "card.title").firstMatch
    }

    private var notesRow: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "card.notes").firstMatch
    }

    /// The notes row is always there now; folded, it shows the first line only. So "open" is
    /// a question about the text, not about the element. Polls, because the display change
    /// animates and the row re-lays out a frame or two later.
    private func waitForNotes(open: Bool) -> Bool {
        let secondLine = "and a second line under it"
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let shown = notesRow.value as? String ?? notesRow.label
            if shown.contains(secondLine) == open { return true }
            usleep(200_000)
        }
        return false
    }

    /// One read, after a fixed settle and a fresh existence check. Deliberately not a polling
    /// loop: querying the same frame in a tight loop keeps handing back the cached
    /// accessibility snapshot, which makes the number a coin flip rather than a measurement.
    private func settledTitleHeight() -> CGFloat {
        usleep(3_000_000)
        XCTAssertTrue(cardTitle.waitForExistence(timeout: 5), "the card title went missing")
        return cardTitle.frame.height
    }

    // MARK: - Seeding

    /// The same files `BoardStore` writes: an index plus one board file, one card in it.
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
            "cards": [[
                "id": UUID().uuidString,
                "title": longTitle,
                "body": notes,
                "columnID": columnID.uuidString,
                "created": stamp,
                "modified": stamp,
            ]],
        ]
        try JSONSerialization.data(withJSONObject: board)
            .write(to: boards.appendingPathComponent("\(boardID.uuidString).json"))
    }
}
