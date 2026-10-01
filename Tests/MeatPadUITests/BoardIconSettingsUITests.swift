import XCTest

/// Settings ▸ Boards: the coloured-icons switch and the per-kind colour rows. Whether the
/// icons really draw in colour is a rendering fact for a human with a screenshot; what this
/// proves is that the tab exists, the switch flips, and the rows answer to it.
///
/// The switch is a real preference, remembered across launches, and the test flips it back
/// before it ends so a run doesn't leave the user's own cards tinted.
final class BoardIconSettingsUITests: XCTestCase {

    private var app: XCUIApplication!
    private var storageRoot = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        continueAfterFailure = false
        storageRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MeatPadUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchArguments = [
            "-meatpad.storageRootOverride", storageRoot.path,
            // A window to be frontmost, so the Settings shortcut has an app to go to.
            "-meatpad.revealBoard", "all",
            "-hasSeenFirstRunIntro", "YES",
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: storageRoot)
    }

    func testBoardsTabOffersColoredIconsAndAResetAll() throws {
        XCTAssertTrue(app.buttons["sidebar.newBoard"].firstMatch.waitForExistence(timeout: 20), "the browser never opened")
        app.typeKey(",", modifierFlags: .command)

        let tab = app.descendants(matching: .any).matching(identifier: "settings-boards-tab").firstMatch
        let byName = app.toolbars.buttons["Boards"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10) || byName.waitForExistence(timeout: 2), "Settings has no Boards tab")
        (tab.exists ? tab : byName).click()

        let toggle = app.descendants(matching: .any).matching(identifier: "settings.board.coloredIcons").firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "the Boards tab has no Colored icons switch")
        // A switch reports 0/1, not a string.
        let before = "\(toggle.value ?? "")"
        toggle.click()
        XCTAssertTrue(poll { "\(toggle.value ?? "")" != before }, "clicking the switch changed nothing")

        let resetAll = app.descendants(matching: .any).matching(identifier: "settings.board.iconColors.resetAll").firstMatch
        XCTAssertTrue(resetAll.exists, "no Reset All Colors button")
        XCTAssertFalse(resetAll.isEnabled, "Reset All Colors is live with no custom colors to reset")

        // Back to how it was found.
        toggle.click()
        XCTAssertTrue(poll { "\(toggle.value ?? "")" == before }, "could not put the switch back")
    }

    private func poll(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(200_000)
        }
        return false
    }
}
