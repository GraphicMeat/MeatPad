import XCTest

/// Opening MeatPad with nothing to restore shows the All Notes browser — what a Dock click
/// shows by default — and not a blank note nobody asked for.
final class LaunchWindowUITests: XCTestCase {

    private var app: XCUIApplication!
    private var storageRoot = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        continueAfterFailure = false
        storageRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MeatPadUITests-\(UUID().uuidString)", isDirectory: true)
        // Empty and existing: a fresh store has no saved session, which is the whole point.
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchArguments = [
            "-meatpad.storageRootOverride", storageRoot.path,
            "-hasSeenFirstRunIntro", "YES",
            // Pinned, so the tester's own Dock-click preference can't pick the other branch.
            "-dockClickAction", "allNotes",
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: storageRoot)
    }

    func testLaunchWithNothingToRestoreOpensAllNotesAndNoBlankNote() {
        XCTAssertTrue(app.windows["All Notes"].waitForExistence(timeout: 20)
                      || app.buttons["sidebar.newBoard"].firstMatch.waitForExistence(timeout: 5),
                      "launch opened no All Notes window")
        // Give a stray note window the time it would need to show up.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(app.windows["Note"].exists, "launch opened a blank note window")
    }
}
