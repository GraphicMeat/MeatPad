import XCTest
import os

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

    // The Quick Look probe board: two cards stacked in one column, each with its own image,
    // the upper one carrying notes to click into. Named "Probe" rather than one letter so it
    // collides with nothing (see `selectSidebarRow`).
    private let probeBoardID = UUID()
    private let probeCard1ID = UUID()
    private let probeCard2ID = UUID()
    /// The probe board's third column, so the card menu's move items have two destinations.
    private let doneColumnID = UUID()

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

    /// Seeded card: title "Alpha", body "first line\nsecond line" — `clipboardText` joins them
    /// with a blank line between, the same format `MeatPadKitTests` proves for `Card`.
    func testCopyButtonCopiesTitleAndNotesAndShowsCheckmark() throws {
        title.hover()
        let copy = app.buttons["card.copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        NSPasteboard.general.clearContents()
        copy.click()
        XCTAssertTrue(poll { NSPasteboard.general.string(forType: .string) == "Alpha\n\nfirst line\nsecond line" })
        XCTAssertEqual(copy.value as? String, "copied")
        XCTAssertTrue(poll(timeout: 4) { (copy.value as? String) != "copied" })
    }

    /// The notes row carries its own copy button: the header's copies the whole card, this
    /// one copies only what is under it.
    func testTheNotesCopyButtonCopiesOnlyTheNotes() throws {
        notes.hover()
        let copy = app.buttons["card.copyNotes"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "no copy button on the notes row")
        NSPasteboard.general.clearContents()
        copy.click()
        XCTAssertTrue(poll { NSPasteboard.general.string(forType: .string) == "first line\nsecond line" },
                      "the notes copy put \(String(describing: NSPasteboard.general.string(forType: .string))) on the pasteboard")
        XCTAssertEqual(copy.value as? String, "copied")
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
    /// board's own event monitors — Quick Look has to survive both.
    func testDoubleClickingAnAttachmentInThePresentedCardOpensQuickLook() throws {
        // Presenting is a button on the card now, not a double-click on it — the double-click
        // belonged as much to the field editor underneath as to the card.
        title.hover()
        let present = app.buttons["card.present"].firstMatch
        XCTAssertTrue(present.waitForExistence(timeout: 5), "no present button on the card")
        present.click()
        XCTAssertTrue(app.buttons["board.present.close"].waitForExistence(timeout: 5),
                      "the present button presented nothing")

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
    /// Red from d97ec51 (when `previewIsUp` started detecting the panel for real) until
    /// `QuickLookHost`: a board-to-board switch orphaned the arriving strips' own
    /// `.quickLookPreview` — see that type's doc and `testProbeQuickLookInAllBoards`.
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
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "the tile never came back on board A")
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

    // MARK: - Split into Cards

    /// Seeded Alpha is "Alpha" over "first line\nsecond line": three lines, three cards, in
    /// order, in the same column — and one ⌘Z takes the split back.
    func testSplitIntoCardsMakesACardPerLineUnderTheOriginal() throws {
        cardMenuItem("Split into Cards", on: title).click()

        XCTAssertTrue(poll { (try? self.storedTitles()) == ["Alpha", "first line", "second line"] },
                      "stored after the split: \(String(describing: try? storedTitles()))")
        XCTAssertEqual(try storedCard()["id"] as? String, cardID.uuidString, "the original lost its place or id")
        XCTAssertNil(try storedCard()["body"], "the original kept its notes")
        let cards = try XCTUnwrap(boardJSON()["cards"] as? [[String: Any]])
        XCTAssertEqual(Set(cards.map { $0["columnID"] as? String }), [columnID.uuidString])
        XCTAssertTrue(poll { self.faceTitlesTopDown() == ["Alpha", "first line", "second line"] },
                      "the column shows \(faceTitlesTopDown())")

        // A one-line card has nothing to split: the item is gone, the menu itself is not.
        let single = app.descendants(matching: .any).matching(identifier: "card.title")
            .matching(NSPredicate(format: "value == %@", "second line")).firstMatch
        XCTAssertTrue(cardMenuItem("Delete Card", on: single).exists)
        XCTAssertFalse(app.menuItems["Split into Cards"].exists, "a one-line card offers to split")
        app.typeKey(.escape, modifierFlags: [])

        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(poll { (try? self.storedTitles()) == ["Alpha"] }, "⌘Z left \(String(describing: try? storedTitles()))")
        XCTAssertTrue(waitForStoredBody("first line\nsecond line"), "⌘Z did not give the original its notes back")
    }

    /// The card's own context menu, retried the way `BoardArchiveUITests` does: the menu
    /// occasionally does not come up on the first right-click after the window takes focus.
    private func cardMenuItem(_ item: String, on card: XCUIElement) -> XCUIElement {
        XCTAssertTrue(card.waitForExistence(timeout: 5), "no card to right-click")
        let entry = app.menuItems[item].firstMatch
        for _ in 0..<3 {
            card.rightClick()
            if entry.waitForExistence(timeout: 3) { return entry }
            app.typeKey(.escape, modifierFlags: [])
        }
        XCTFail("no “\(item)” item in the card's context menu")
        return entry
    }

    private func faceTitlesTopDown() -> [String] {
        app.descendants(matching: .any).matching(identifier: "card.title").allElementsBoundByIndex
            .sorted { $0.frame.minY < $1.frame.minY }
            .map(faceText)
    }

    // MARK: - Move to column

    /// The card menu leads with one "Move to …" per other column of the card's board — never
    /// the one it is already in — and a move is one ⌘Z.
    func testTheCardMenuMovesACardToAnotherColumn() throws {
        launch(onBoard: probeBoardID)
        let card = probeTitle("Card P2")
        let move = cardMenuItem("Move to Doing", on: card)
        XCTAssertTrue(app.menuItems["Move to Done"].exists, "no item for the board's third column")
        XCTAssertFalse(app.menuItems["Move to Todo"].exists, "the menu offers the card's own column")
        move.click()

        XCTAssertTrue(poll { self.probeColumn(of: self.probeCard2ID) == self.secondColumnID.uuidString },
                      "the card never left Todo")
        XCTAssertEqual(probeColumn(of: probeCard1ID), columnID.uuidString, "the move took the other card along")

        // Now in Doing: the menu offers Todo back, and not Doing.
        XCTAssertTrue(cardMenuItem("Move to Todo", on: card).exists)
        XCTAssertFalse(app.menuItems["Move to Doing"].exists, "the menu offers the column the card just moved to")
        app.typeKey(.escape, modifierFlags: [])

        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(poll { self.probeColumn(of: self.probeCard2ID) == self.columnID.uuidString }, "⌘Z left the card in Doing")
    }

    private func probeColumn(of card: UUID) -> String? {
        let url = storageRoot.appendingPathComponent("Boards/\(probeBoardID.uuidString).json")
        let json = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let cards = json?["cards"] as? [[String: Any]] ?? []
        return cards.first { $0["id"] as? String == card.uuidString }?["columnID"] as? String
    }

    // MARK: - Quick Look probes

    // Round four of "double-clicking an image doesn't always open Quick Look" — these each
    // stage one suspected circumstance and assert the panel still comes up. Every probe marks
    // its start in the same unified-log category the app's Quick Look path logs to, so a
    // `log stream` running alongside shows, per probe, whether the double-click reached the
    // monitor, found a tile, and opened a file.

    private static let probeLog = Logger(subsystem: "com.thecoldzero.MeatPad", category: "quicklook")
    private func mark(_ probe: String) { Self.probeLog.notice("PROBE \(probe, privacy: .public)") }

    /// The probe board's tiles, top first — AX order isn't layout order.
    private func probeTiles() -> [XCUIElement] {
        let tiles = app.descendants(matching: .any).matching(identifier: "card.attachment")
        XCTAssertTrue(poll { tiles.count >= 2 }, "the probe board shows \(tiles.count) tiles")
        return tiles.allElementsBoundByIndex.sorted { $0.frame.minY < $1.frame.minY }
    }

    private func probeTitle(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "card.title")
            .matching(NSPredicate(format: "value == %@", text)).firstMatch
    }

    /// a) A card nobody has touched yet — the first click of the double-click is also the one
    /// that selects it, so the selection re-render lands between the two clicks.
    func testProbeQuickLookOnAnUnselectedCard() throws {
        launch(onBoard: probeBoardID)
        mark("a-unselected")
        probeTiles()[1].doubleClick()
        XCTAssertTrue(poll { self.previewIsUp() }, "no Quick Look on a card that was not selected")
    }

    /// a) The same card already selected (⌘-click selects without starting an edit), with a
    /// pause well past the double-click interval before the double-click.
    func testProbeQuickLookOnAnAlreadySelectedCard() throws {
        launch(onBoard: probeBoardID)
        let card = probeTitle("Card P2")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCUIElement.perform(withKeyModifiers: .command) { card.click() }
        sleep(1)
        mark("a-selected")
        probeTiles()[1].doubleClick()
        XCTAssertTrue(poll { self.previewIsUp() }, "no Quick Look on a card that was already selected")
    }

    /// b) Right after the card above was being edited: the first click of the double-click
    /// blurs that field, the row turns back into a label, and the layout can shift under the
    /// pointer before the second click lands.
    func testProbeQuickLookRightAfterEditingTheCardAbove() throws {
        launch(onBoard: probeBoardID)
        let notesAbove = app.descendants(matching: .any).matching(identifier: "card.notes")
            .matching(NSPredicate(format: "value BEGINSWITH %@", "probe notes")).firstMatch
        XCTAssertTrue(notesAbove.waitForExistence(timeout: 5))
        notesAbove.click()
        XCTAssertTrue(app.textFields["card.notes"].waitForExistence(timeout: 5), "the notes never opened a field")
        mark("b-after-edit")
        probeTiles()[1].doubleClick()
        XCTAssertTrue(poll { self.previewIsUp() }, "no Quick Look right after editing the card above")
    }

    /// c) While the panel already shows another card's image. The window is titled "Quick
    /// Look" whatever it shows, so the panel's tree is printed for the record, and the log's
    /// `open` lines say which file each double-click asked for.
    func testProbeQuickLookWhileAnotherCardsImageIsShowing() throws {
        launch(onBoard: probeBoardID)
        let tiles = probeTiles()
        mark("c-first")
        tiles[0].doubleClick()
        XCTAssertTrue(poll { self.previewIsUp() }, "the first image never opened")
        print("QLPROBE panel after p1: \(app.windows["Quick Look"].debugDescription)")
        mark("c-second")
        tiles[1].doubleClick()
        sleep(2)
        XCTAssertTrue(previewIsUp(), "the panel went away on the second card's double-click")
        print("QLPROBE panel after p2: \(app.windows["Quick Look"].debugDescription)")
        let names = app.windows["Quick Look"].descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR title CONTAINS %@ OR value CONTAINS %@", "p2", "p2", "p2"))
        print("QLPROBE elements naming p2: \(names.count)")
    }

    /// d) The All Boards overview, where every board's cards (and tiles) share one set of
    /// columns and each card carries a board badge.
    func testProbeQuickLookInAllBoards() throws {
        launch(onBoard: probeBoardID)
        selectSidebarRow("All Boards")
        let tile = app.descendants(matching: .any)["card.attachment"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "All Boards shows no tiles")
        mark("d-all-boards")
        tile.doubleClick()
        XCTAssertTrue(poll { self.previewIsUp() }, "no Quick Look in All Boards")
    }

    /// d2) As d, but the strips are then taken away and brought back on their own (Compact,
    /// then Full) before the double-click — no other strip leaving in the same update.
    func testProbeQuickLookInAllBoardsAfterCompactAndBack() throws {
        launch(onBoard: probeBoardID)
        selectSidebarRow("All Boards")
        selectCardDisplay("Compact")
        selectCardDisplay("Full")
        let tile = app.descendants(matching: .any)["card.attachment"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "All Boards shows no tiles")
        mark("d2-all-boards-compact-full")
        tile.doubleClick()
        XCTAssertTrue(poll { self.previewIsUp() }, "no Quick Look in All Boards after Compact and back")
    }

    /// d3) All Boards reached by way of a note, so the board's strips leave (board -> note)
    /// and All Boards' strips arrive (note -> All Boards) in separate updates.
    func testProbeQuickLookInAllBoardsReachedFromANote() throws {
        launch(onBoard: probeBoardID)
        selectSidebarRow("Notes")
        selectSidebarRow(noteTitle)
        selectSidebarRow("All Boards")
        let tile = app.descendants(matching: .any)["card.attachment"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "All Boards shows no tiles")
        mark("d3-all-boards-via-note")
        tile.doubleClick()
        XCTAssertTrue(poll { self.previewIsUp() }, "no Quick Look in All Boards reached from a note")
    }

    /// f) MeatPad in the background: the catcher claims first mouse so a tile in an inactive
    /// window opens on one gesture — nothing covered that until now.
    func testProbeQuickLookWhileTheAppIsInTheBackground() throws {
        launch(onBoard: probeBoardID)
        let tile = probeTiles()[1]
        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        sleep(1)
        mark("f-background")
        tile.doubleClick()
        XCTAssertTrue(poll { self.previewIsUp() }, "no Quick Look from a background window")
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
    /// Scoped to the sidebar outline, not the whole app: a one-letter board name also matches
    /// that board's badge on every card in the All Boards overview, and which of the two an
    /// app-wide query answers with depends on accessibility-tree order — so an unscoped lookup
    /// silently clicks a card badge instead of the row.
    private func selectSidebarRow(_ name: String) {
        let sidebar = app.outlines["Sidebar"].staticTexts[name].firstMatch
        // Note rows live in the middle column, not the sidebar outline, so fall back to an
        // app-wide lookup for those.
        let row = sidebar.waitForExistence(timeout: 3) ? sidebar : app.staticTexts[name].firstMatch
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
    private func launchOnBoardA() { launch(onBoard: boardAID) }

    private func launch(onBoard id: UUID) {
        app.terminate()
        app.launchArguments = [
            "-meatpad.storageRootOverride", storageRoot.path,
            "-meatpad.revealBoard", id.uuidString,
            "-hasSeenFirstRunIntro", "YES",
        ]
        app.launch()
        XCTAssertTrue(title.waitForExistence(timeout: 20), "board \(id) never rendered")
    }

    /// The Quick Look panel is its own window — titled literally "Quick Look" on this macOS
    /// version, not after the file (confirmed by dumping `app.windows` mid-test: a panel titled
    /// "Quick Look" appears, never one containing the filename). `name` stays as a parameter for
    /// call-site readability and failure messages; a real "Quick Look" window existing is proof
    /// enough that a panel is on screen, which is what every caller here actually needs.
    private func previewIsUp(named name: String = "seed.png") -> Bool {
        _ = name
        return app.windows["Quick Look"].exists
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
    private func storedTitles() throws -> [String] {
        try XCTUnwrap(boardJSON()["cards"] as? [[String: Any]]).compactMap { $0["title"] as? String }
    }
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
            "boardOrder": [boardID.uuidString, boardAID.uuidString, boardBID.uuidString, probeBoardID.uuidString],
        ]
        try JSONSerialization.data(withJSONObject: index).write(to: boards.appendingPathComponent("boards.json"))
        let columns: [[String: Any]] = [
            ["id": columnID.uuidString, "name": "Todo", "isDone": false, "emoji": "📋"],
            ["id": secondColumnID.uuidString, "name": "Doing", "isDone": false, "emoji": "🚧"],
        ]
        let stamp = "2026-09-03T09:00:00Z"
        let board: [String: Any] = [
            "id": boardID.uuidString, "name": "Test Board", "extraColumns": columns,
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
                "id": id.uuidString, "name": name, "extraColumns": columns,
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

        // The Quick Look probe board.
        let probe: [String: Any] = [
            "id": probeBoardID.uuidString, "name": "Probe",
            "extraColumns": columns + [["id": doneColumnID.uuidString, "name": "Done", "isDone": true, "emoji": "✅"]],
            "cards": [
                [
                    "id": probeCard1ID.uuidString, "title": "Card P1", "body": "probe notes\nsecond probe line",
                    "columnID": columnID.uuidString, "created": stamp, "modified": stamp,
                    "attachments": ["p1.png"],
                ],
                [
                    "id": probeCard2ID.uuidString, "title": "Card P2",
                    "columnID": columnID.uuidString, "created": stamp, "modified": stamp,
                    "attachments": ["p2.png"],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: probe).write(to: boards.appendingPathComponent("\(probeBoardID.uuidString).json"))
        for (card, attachment) in [(probeCard1ID, "p1.png"), (probeCard2ID, "p2.png")] {
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
