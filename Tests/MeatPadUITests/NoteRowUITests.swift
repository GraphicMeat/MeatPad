import XCTest

/// A note made from the All Notes toolbar shows its date line straight away. It was reported
/// coming up as a single squashed line that only grew its date later.
final class NoteRowUITests: XCTestCase {

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
            "-hasSeenFirstRunIntro", "YES",
            "-dockClickAction", "allNotes",
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: storageRoot)
    }

    func testANewNoteRowHasItsDateAtOnce() {
        XCTAssertTrue(app.windows["All Notes"].waitForExistence(timeout: 20), "no All Notes window")
        app.typeKey("n", modifierFlags: [.command, .option])
        XCTAssertTrue(app.staticTexts["New Note"].firstMatch.waitForExistence(timeout: 5), "⌘⌥N listed no new note")
        // Well inside the minute a once-a-minute refresh would need to fill the date in.
        usleep(500_000)
        XCTAssertTrue(app.staticTexts["now"].firstMatch.exists, "the new note's row has no date line")
    }
}
