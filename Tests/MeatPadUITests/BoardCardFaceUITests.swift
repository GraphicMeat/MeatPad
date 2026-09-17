import XCTest

/// The card face renders Text until a row is clicked. That is what lets a drag start on the
/// title and what makes ⌘Z reach the store instead of an NSTextField — neither is visible
/// to a unit test.
final class BoardCardFaceUITests: XCTestCase {
    private var app: XCUIApplication!
    private var storageRoot: URL!
    private let boardID = UUID()
    private let columnID = UUID()
    private let secondColumnID = UUID()
    private let cardID = UUID()

    // Two more boards for the view-switch regression tests below, each with one card and one
    // attachment, plus a note — so the sidebar has all three row kinds to switch between.
    private let boardAID = UUID()
    private let boardBID = UUID()
    private let cardAID = UUID()
    private let cardBID = UUID()
    private let noteID = UUID()
    private let noteTitle = "Note C"

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
        XCTAssertTrue(title.waitForExistence(timeout: 20), "board never rendered")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: storageRoot)
    }

    private var title: XCUIElement { app.descendants(matching: .any).matching(identifier: "card.title").firstMatch }
    private var notes: XCUIElement { app.descendants(matching: .any).matching(identifier: "card.notes").firstMatch }

    /// An idle row is a `Text` carrying a button trait and an editing one is a `TextField`, so
    /// the text is read from whichever of value/label the row is exposing — never by asking
    /// for an element type.
    private func faceText(_ element: XCUIElement) -> String {
        element.value as? String ?? element.label
    }

    func testClickingTheTitleEditsItAndBlurCommits() throws {
        title.click()
        XCTAssertTrue(app.textFields["card.title"].waitForExistence(timeout: 5), "the click opened no field")
        app.typeText("!")
        app.staticTexts["Todo"].firstMatch.click()   // blur

        XCTAssertTrue(poll { self.faceText(self.title) == "Alpha!" }, "the edit never landed on the face")
        XCTAssertEqual(try storedTitle(), "Alpha!")
    }

    func testDraggingTheTitleMovesTheCardToAnotherColumn() throws {
        let target = app.staticTexts["Doing"].firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        title.click(forDuration: 0.4, thenDragTo: target)

        XCTAssertTrue(waitForStoredColumn(secondColumnID), "the card never left its column")
    }

    func testCommandZRevertsANotesEdit() throws {
        notes.click()
        XCTAssertTrue(app.textFields["card.notes"].waitForExistence(timeout: 5))
        app.typeText(" typed")
        app.staticTexts["Todo"].firstMatch.click()   // blur → commit
        XCTAssertTrue(waitForStoredBody("first line\nsecond line typed"))
        XCTAssertTrue(app.staticTexts["card.notes"].waitForExistence(timeout: 5), "the row never blurred back to text")

        app.typeKey("z", modifierFlags: .command)

        XCTAssertTrue(waitForStoredBody("first line\nsecond line"), "⌘Z did not revert the notes")
        XCTAssertEqual(faceText(notes), "first line\nsecond line")
    }

    func testUndoButtonRevertsATitleEdit() throws {
        title.click()
        app.typeText("!")
        app.staticTexts["Todo"].firstMatch.click()
        XCTAssertEqual(try storedTitle(), "Alpha!")

        let undo = app.buttons["board.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        XCTAssertTrue(undo.isEnabled)
        undo.click()

        XCTAssertTrue(poll { self.faceText(self.title) == "Alpha" }, "the face kept the undone title")
        XCTAssertEqual(try storedTitle(), "Alpha")
    }

    func testASeededAttachmentIsShownOnTheFaceAndRemovableInTheEditor() throws {
        XCTAssertTrue(app.descendants(matching: .any)["card.attachment"].firstMatch.waitForExistence(timeout: 5),
                      "the face shows no thumbnail for a seeded attachment")
        app.buttons["card.actions"].firstMatch.click()
        let thumb = app.descendants(matching: .any)["cardEditor.attachment"].firstMatch
        XCTAssertTrue(thumb.waitForExistence(timeout: 5))
        thumb.hover()
        let remove = app.buttons["cardEditor.attachment.remove"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.click()
        XCTAssertTrue(poll { (try? self.storedCard()["attachments"] as? [String]) == nil },
                      "the card kept its attachment name")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: storageRoot.appendingPathComponent("Boards/Attachments/\(cardID.uuidString)/seed.png").path))
    }

    /// Quick Look is a click gesture the tile has to win against the row's drag and the
    /// board's own double-click — and it must not fire on a single click, which is how a
    /// card gets selected.
    func testDoubleClickingAnAttachmentOpensQuickLook() throws {
        let tile = app.descendants(matching: .any)["card.attachment"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5))

        tile.click()
        XCTAssertFalse(poll(timeout: 2) { self.previewIsUp() }, "a single click opened a preview")

        tile.doubleClick()
        XCTAssertTrue(poll { self.previewIsUp() }, "the double click opened no Quick Look panel")
    }

    func testDoubleClickingAnAttachmentDoesNotPresentTheCard() throws {
        let tile = app.descendants(matching: .any)["card.attachment"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        tile.doubleClick()
        XCTAssertFalse(app.buttons["board.present.close"].waitForExistence(timeout: 2),
                       "the tile's own double-click presented the card instead")
    }

    /// The presented copy of a card carries the same tiles, and the overlay sits over the
    /// board's own double-click monitor — Quick Look has to survive both.
    func testDoubleClickingAnAttachmentInThePresentedCardOpensQuickLook() throws {
        title.doubleClick()
        XCTAssertTrue(app.buttons["board.present.close"].waitForExistence(timeout: 5),
                      "the double click presented nothing")

        // Two tiles carry the identifier now — the row behind the backdrop and the presented
        // copy, which is the bigger of the two.
        let tile = app.descendants(matching: .any).matching(identifier: "card.attachment")
            .allElementsBoundByIndex.max { $0.frame.width < $1.frame.width }
        try XCTUnwrap(tile).doubleClick()
        XCTAssertTrue(poll { self.previewIsUp() }, "the double click opened no Quick Look panel")
    }

    /// Rokas 2026-09-17: "it worked - then it stopped working after switching between views".
    /// CAUSE CONFIRMED — H5 (stale binding): `AttachmentStrip`'s `@State preview` doesn't
    /// always get written back to `nil` when the Quick Look panel closes, so a view switch can
    /// leave it `== url`; the next double-click assigns the same value and nothing happens.
    /// Only this one leaves the panel up across the switch — the path where SwiftUI is least
    /// likely to have written `preview` back to `nil` on its own. The other three below press
    /// Escape first (a clean close) before switching, so pre-fix they may not reproduce H5;
    /// this is the one that carries the regression weight.
    func testQuickLookOpensAgainAfterClosingItAndSwitchingBoards() throws {
        launchOnBoardA()
        let tile = app.descendants(matching: .any)["card.attachment"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        tile.doubleClick()
        XCTAssertTrue(poll { self.previewIsUp(named: "a.png") }, "first open")
        try shoot("switch-boards-first-open")
        app.typeKey(.escape, modifierFlags: [])                       // close the panel
        XCTAssertTrue(poll { !self.previewIsUp(named: "a.png") })
        selectSidebarRow("B"); selectSidebarRow("A")                  // switch away and back
        tile.doubleClick()
        XCTAssertTrue(poll { self.previewIsUp(named: "a.png") }, "same image after a view switch")
        try shoot("switch-boards-after-switch")
    }

    /// This is the one that most directly reproduces H5: the panel is still up when the board
    /// is left, so nothing ever gets the chance to write `preview` back to `nil` on a clean
    /// close.
    func testQuickLookOpensAfterSwitchingViewsWhileThePanelIsStillOpen() throws {
        launchOnBoardA()
        let tile = app.descendants(matching: .any)["card.attachment"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        tile.doubleClick()
        XCTAssertTrue(poll { self.previewIsUp(named: "a.png") })
        try shoot("panel-open-first-open")
        selectSidebarRow("All Boards")                                // leave with the panel up
        selectSidebarRow("A")
        if previewIsUp(named: "a.png") { app.typeKey(.escape, modifierFlags: []) }
        tile.doubleClick()
        XCTAssertTrue(poll { self.previewIsUp(named: "a.png") }, "after leaving the board with the panel open")
        try shoot("panel-open-after-switch")
    }

    /// Compact removes every `AttachmentStrip` from the tree; Full brings it back. The
    /// `preview` state has to be re-armed by the fix the same way a full view switch is.
    func testQuickLookOpensAfterCardDisplayCompactAndBack() throws {
        launchOnBoardA()
        let tile = app.descendants(matching: .any)["card.attachment"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        tile.doubleClick()
        XCTAssertTrue(poll { self.previewIsUp(named: "a.png") })
        try shoot("card-display-first-open")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(poll { !self.previewIsUp(named: "a.png") })

        selectCardDisplay("Compact")
        selectCardDisplay("Full")

        XCTAssertTrue(tile.waitForExistence(timeout: 5), "the tile never came back in Full")
        tile.doubleClick()
        XCTAssertTrue(poll { self.previewIsUp(named: "a.png") }, "same image after Compact then Full")
        try shoot("card-display-after-switch")
    }

    /// The other half of "switching between views": leaving the board entirely for a note and
    /// coming back, rather than staying inside the board-scoped views above.
    func testQuickLookOpensAfterSwitchingToANoteAndBackToTheBoard() throws {
        launchOnBoardA()
        let tile = app.descendants(matching: .any)["card.attachment"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        tile.doubleClick()
        XCTAssertTrue(poll { self.previewIsUp(named: "a.png") })
        try shoot("board-note-first-open")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(poll { !self.previewIsUp(named: "a.png") })

        selectSidebarRow("Notes")
        selectSidebarRow(noteTitle)                                   // the note row
        selectSidebarRow("A")

        XCTAssertTrue(tile.waitForExistence(timeout: 5), "the tile never came back on the board")
        tile.doubleClick()
        XCTAssertTrue(poll { self.previewIsUp(named: "a.png") }, "same image after a board-to-note switch")
        try shoot("board-note-after-switch")
    }

    /// The runner's own tmp dir, because its sandbox cannot write anywhere else (same pattern
    /// as `BoardPresentUITests.shoot`). Not just layout sign-off here: if `previewIsUp()`'s
    /// assumption that the Quick Look window's title contains the filename turns out wrong,
    /// these are what tells a green-vs-red run apart from a broken assertion.
    private func shoot(_ name: String) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("card-face-\(name).png")
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
        print("SHOT \(url.path)")
    }

    // MARK: - Driving the sidebar and card-display control

    /// Every sidebar row — a board, "All Boards", a folder, a note — is a plain `Text`, so one
    /// query drives them all, the same way `BoardIconUITests`/`BoardLabelUITests` click a row
    /// by its label.
    private func selectSidebarRow(_ name: String) {
        let row = app.staticTexts[name].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no sidebar row named “\(name)”")
        row.click()
    }

    private func selectCardDisplay(_ label: String) {
        let segment = app.radioButtons[label]
        XCTAssertTrue(segment.waitForExistence(timeout: 5), "no “\(label)” segment in the card display control")
        segment.click()
    }

    /// The shared fixture launches onto the original board (`boardID`) so the six tests above
    /// stay untouched; the view-switch tests need Board A on screen instead, with its own
    /// `a.png` tile already resolvable — relaunched the same way `BoardLabelUITests.showAllBoards()`
    /// switches views.
    private func launchOnBoardA() {
        app.terminate()
        app.launchArguments = [
            "-meatpad.storageRootOverride", storageRoot.path,
            "-meatpad.revealBoard", boardAID.uuidString,
            "-hasSeenFirstRunIntro", "YES",
        ]
        app.launch()
        XCTAssertTrue(title.waitForExistence(timeout: 20), "board A never rendered")
    }

    /// The Quick Look panel is its own window titled after the file. Anything less (a label
    /// somewhere, any extra window) passed without a preview ever being on screen.
    private func previewIsUp(named name: String = "seed.png") -> Bool {
        app.windows.matching(NSPredicate(format: "title CONTAINS[c] %@", name)).count > 0
    }

    // MARK: - Reading the store

    private func boardJSON() throws -> [String: Any] {
        let url = storageRoot.appendingPathComponent("Boards/\(boardID.uuidString).json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    private func storedCard() throws -> [String: Any] {
        try XCTUnwrap((boardJSON()["cards"] as? [[String: Any]])?.first)
    }
    private func storedTitle() throws -> String { try XCTUnwrap(storedCard()["title"] as? String) }
    private func waitForStoredBody(_ expected: String) -> Bool { poll { (try? self.storedCard()["body"] as? String) == expected } }
    private func waitForStoredColumn(_ id: UUID) -> Bool { poll { (try? self.storedCard()["columnID"] as? String) == id.uuidString } }
    private func poll(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if condition() { return true }; usleep(200_000) }
        return false
    }

    // MARK: - Seeding

    private func seedBoard() throws {
        let boards = storageRoot.appendingPathComponent("Boards", isDirectory: true)
        try FileManager.default.createDirectory(at: boards, withIntermediateDirectories: true)
        let index: [String: Any] = [
            "boardOrder": [boardID.uuidString, boardAID.uuidString, boardBID.uuidString],
            "globalColumns": [
                ["id": columnID.uuidString, "name": "Todo", "isDone": false, "emoji": "📋"],
                ["id": secondColumnID.uuidString, "name": "Doing", "isDone": false, "emoji": "🚧"],
            ],
        ]
        try JSONSerialization.data(withJSONObject: index).write(to: boards.appendingPathComponent("boards.json"))
        let stamp = "2026-09-03T09:00:00Z"
        let board: [String: Any] = [
            "id": boardID.uuidString, "name": "Test Board", "extraColumns": [],
            "cards": [[
                "id": cardID.uuidString, "title": "Alpha", "body": "first line\nsecond line",
                "columnID": columnID.uuidString, "created": stamp, "modified": stamp,
                "attachments": ["seed.png"],
            ]],
        ]
        try JSONSerialization.data(withJSONObject: board).write(to: boards.appendingPathComponent("\(boardID.uuidString).json"))

        // The file has to exist too: a name on the record with nothing behind it draws an
        // empty tile, which would let the face test pass on a thumbnail that never decoded.
        let attachments = boards.appendingPathComponent("Attachments/\(cardID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try Self.onePixelPNG.write(to: attachments.appendingPathComponent("seed.png"))

        // Two more boards for the view-switch regression tests: one card each, one attachment
        // (a.png / b.png), so a double-click after switching away and back has a name to prove.
        for (id, card, name, attachment) in [
            (boardAID, cardAID, "A", "a.png"),
            (boardBID, cardBID, "B", "b.png"),
        ] as [(UUID, UUID, String, String)] {
            let sideBoard: [String: Any] = [
                "id": id.uuidString, "name": name, "extraColumns": [],
                "cards": [[
                    "id": card.uuidString, "title": "Card \(name)",
                    "columnID": columnID.uuidString, "created": stamp, "modified": stamp,
                    "attachments": [attachment],
                ]],
            ]
            try JSONSerialization.data(withJSONObject: sideBoard).write(to: boards.appendingPathComponent("\(id.uuidString).json"))
            let dir = boards.appendingPathComponent("Attachments/\(card.uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Self.onePixelPNG.write(to: dir.appendingPathComponent(attachment))
        }

        // One note, so the sidebar also has a "Notes" row and the note's own row to switch to
        // and back from — `NoteStore` self-heals a missing JSON sidecar from the `.txt` alone.
        let notes = storageRoot.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try Data(noteTitle.utf8).write(to: notes.appendingPathComponent("\(noteID.uuidString).txt"))
    }

    /// A 1×1 red PNG — the smallest thing `CGImageSource` will make a thumbnail out of.
    private static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==")!
}
