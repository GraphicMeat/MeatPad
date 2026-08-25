import XCTest

/// Marketing screenshots for graphicmeat.com, captured by driving the real app.
///
/// This is not an assertion suite — it is the capture step of the site's screenshot pipeline
/// ([[meatpad-site-screenshots]]), moved from `capture.sh` into XCUITest because the features
/// that now need showing cannot be photographed by fronting a window: the card editor has to
/// be opened, and the board has to be caught in a particular state.
///
/// It is inert unless `SHOT_LOCALE` is set, so ordinary `-only-testing:MeatPadUITests` runs
/// skip it. Drive it per locale:
///
///     xcodebuild test -only-testing:MeatPadUITests/BoardShotUITests \
///       TEST_RUNNER_SHOT_LOCALE=de TEST_RUNNER_SHOT_REGION=de_DE \
///       TEST_RUNNER_SHOT_ROOT=/Users/unicorn/meatpad-shots/store-de
///
/// The seeded root comes from `scripts/seed-demo-store.py`; the window size comes from the
/// app's own `NSWindow Frame all-notes` default, which the driver writes before the run (the
/// key contains a space, so it cannot ride in on launch arguments).
final class BoardShotUITests: XCTestCase {

    private static let boardID = "3F2B1A64-0C7E-4D51-9E2A-5B8C41D0A7E3"

    private var app: XCUIApplication!
    private var locale = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        locale = env["SHOT_LOCALE"] ?? ""
        try XCTSkipIf(locale.isEmpty, "SHOT_LOCALE unset — this suite only runs from the shot driver")
        let root = try XCTUnwrap(env["SHOT_ROOT"], "SHOT_ROOT is required")
        let region = env["SHOT_REGION"] ?? "en_US"

        app = XCUIApplication()
        app.launchArguments = [
            "-meatpad.storageRootOverride", root,
            "-meatpad.revealBoard", Self.boardID,
            "-hasSeenFirstRunIntro", "YES",
            // Region as well as language: with only -AppleLanguages the mini's own region
            // formats the inline due date as a ragged "23/ 8/2026, 16:00".
            "-AppleLanguages", "(\(locale))",
            "-AppleLocale", region,
        ]
        app.launch()
        XCTAssertTrue(app.textFields.matching(identifier: "card.title").firstMatch.waitForExistence(timeout: 30),
                      "board never rendered for \(locale)")
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    /// Shot 1: the board itself — coloured label badges, two cards carrying their own colour,
    /// the search field and the density picker in the header row.
    /// Shot 2: the card editor open over it.
    func testCaptureBoardShots() throws {
        parkPointer()
        settle()
        save(window(), as: "07-boards")

        openEditorOnFirstCard()
        parkPointer()
        settle()
        save(window(), as: "08-card-editor")
    }

    // MARK: - Driving

    private func openEditorOnFirstCard() {
        let menu = app.descendants(matching: .any).matching(identifier: "card.actions").element(boundBy: 0)
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "no card ⋯ button")
        menu.click()
        XCTAssertTrue(element("cardEditor.title").waitForExistence(timeout: 10), "the editor never opened")
    }

    /// Move the pointer off every control before the shutter.
    ///
    /// The pointer survives between launches, so in a nine-locale loop each run starts with
    /// the mouse still resting where the previous run clicked a card's ⋯ — and macOS helpfully
    /// paints its "Card Actions" help tag over the board, localized, right across a due date.
    /// The bottom-right of the window is empty in every locale.
    private func parkPointer() {
        window().coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.93)).hover()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// A fixed sleep, not a polling loop: polling hands back the CACHED accessibility snapshot
    /// and settles on a stale frame, and here it would also photograph a half-finished
    /// entrance animation.
    private func settle() {
        usleep(3_000_000)
    }

    // MARK: - Capturing

    private func window() -> XCUIElement {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "no window to capture")
        return window
    }

    /// The runner is sandboxed and cannot write to /private/tmp, so the PNG goes to its own
    /// container tmp and the path is printed for the driver to copy out.
    private func save(_ element: XCUIElement, as name: String) {
        let data = element.screenshot().pngRepresentation
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(locale).png")
        do {
            try data.write(to: url)
            print("SHOT_WROTE \(url.path) \(data.count)")
        } catch {
            XCTFail("could not write \(name) for \(locale): \(error)")
        }
    }
}
