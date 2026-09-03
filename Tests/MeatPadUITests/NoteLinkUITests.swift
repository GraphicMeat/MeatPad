import XCTest

/// Links in a note: drawn in the editor, and explained once when one is pasted. The drawing
/// is attribute work inside STTextView that no unit test can see, so each check also writes a
/// PNG (path printed as `SHOT_WROTE`) for a human to look at.
final class NoteLinkUITests: XCTestCase {
    private var app: XCUIApplication!
    private var storageRoot: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeatPadUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchArguments = [
            "-meatpad.storageRootOverride", storageRoot.path,
            "-hasSeenFirstRunIntro", "YES",
            "-meatpad.suppressLinkOpen", "YES",
            // The hint is per-user state; a run must not depend on whether an earlier one
            // silenced it.
            "-linkPasteHint.suppressed", "NO",
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: storageRoot)
    }

    func testALinkIsDrawnAndAPasteExplainsHowToOpenIt() throws {
        newNote()
        app.typeText("Docs live at https://example.com/handbook — read it.\n")
        // Link decoration rides the 150 ms highlight debounce; a shot taken the instant
        // typing stops catches the text before it is drawn.
        Thread.sleep(forTimeInterval: 1.5)
        save("note-with-link")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("https://example.com/pasted", forType: .string)
        app.typeKey("v", modifierFlags: .command)

        let hint = app.descendants(matching: .any).matching(identifier: "linkHint").firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 5), "pasting a link said nothing about how to open it")
        save("note-link-hint")
        // A `.link`-styled button is not an AXButton, so ask by identifier, not by type.
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "linkHint.settings").firstMatch.exists,
                      "the hint offers no way to change the setting")

        // Eight seconds, plus room for the animation: the hint is a note, not a decision.
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: hint)
        waitForExpectations(timeout: 15)
    }

    // MARK: - Helpers

    private func newNote() {
        let menu = app.menuBars.menuBarItems["File"]
        XCTAssertTrue(menu.waitForExistence(timeout: 20), "no File menu")
        menu.click()
        app.menuItems["New Note"].firstMatch.click()
        XCTAssertTrue(app.windows["Note"].waitForExistence(timeout: 10), "New Note opened no window")
    }

    /// The runner is sandboxed out of /private/tmp, so PNGs go to its own container tmp and
    /// the path is printed for whoever is driving the run.
    private func save(_ name: String) {
        let data = app.windows.firstMatch.screenshot().pngRepresentation
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
        do {
            try data.write(to: url)
            print("SHOT_WROTE \(url.path) \(data.count)")
        } catch {
            XCTFail("could not write \(name): \(error)")
        }
    }
}
