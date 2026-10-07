import XCTest

/// "A note left with nothing in it is junk", outside a note window: a note made in All Notes and
/// never typed into is gone once the selection moves on, and one left behind on disk is swept
/// at launch. Reported as a selected, empty "New Note" row nobody could get rid of.
final class NoteDiscardUITests: XCTestCase {

    private var app: XCUIApplication!
    private var storageRoot = URL(fileURLWithPath: "/")
    private var notesFolder: URL { storageRoot.appendingPathComponent("Notes", isDirectory: true) }
    private let keeperID = UUID()

    override func setUpWithError() throws {
        continueAfterFailure = false
        storageRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MeatPadUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: notesFolder, withIntermediateDirectories: true)
        // Something else to select.
        try seedNote(keeperID, contents: "Keeper")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: storageRoot)
    }

    /// NoteStore's on-disk pair: `<id>.txt` holds the contents, `<id>.json` the sidecar.
    private func seedNote(_ id: UUID, contents: String) throws {
        try Data(contents.utf8).write(to: notesFolder.appendingPathComponent("\(id.uuidString).txt"))
        let title = contents.isEmpty ? "New Note" : contents
        let sidecar = #"{"id":"\#(id.uuidString)","created":"2026-10-01T09:00:00Z","modified":"2026-10-01T09:00:00Z","cursor":0,"title":"\#(title)"}"#
        try Data(sidecar.utf8).write(to: notesFolder.appendingPathComponent("\(id.uuidString).json"))
    }

    private func launch() {
        app = XCUIApplication()
        app.launchArguments = [
            "-meatpad.storageRootOverride", storageRoot.path,
            "-hasSeenFirstRunIntro", "YES",
            "-dockClickAction", "allNotes",
        ]
        app.launch()
        XCTAssertTrue(app.windows["All Notes"].waitForExistence(timeout: 20), "no All Notes window")
        XCTAssertTrue(app.staticTexts["Keeper"].firstMatch.waitForExistence(timeout: 10), "the seeded note isn't listed")
    }

    /// The `.txt` and `.json` files directly in `Notes/` (not the trash).
    private func noteFiles() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: notesFolder.path)) ?? []
        return Set(names.filter { $0.hasSuffix(".txt") || $0.hasSuffix(".json") })
    }

    private var keeperFiles: Set<String> { ["\(keeperID.uuidString).txt", "\(keeperID.uuidString).json"] }

    private func eventually(_ message: String, timeout: TimeInterval = 10, _ condition: () -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTFail(message, file: file, line: line)
    }

    private func newNoteInBrowser() {
        app.typeKey("n", modifierFlags: [.command, .option])
        XCTAssertTrue(app.staticTexts["New Note"].firstMatch.waitForExistence(timeout: 5), "⌘⌥N listed no new note")
        XCTAssertEqual(noteFiles().count, 4, "positive control: the new note isn't on disk")
    }

    private func selectKeeper() {
        app.staticTexts["Keeper"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    func testAnUntouchedNewNoteIsDiscardedWhenAnotherNoteIsSelected() {
        launch()
        newNoteInBrowser()
        selectKeeper()
        eventually("the empty note is still on disk: \(noteFiles())") { self.noteFiles() == self.keeperFiles }
        XCTAssertTrue(app.staticTexts["New Note"].firstMatch.waitForNonExistence(timeout: 5), "the empty note is still listed")
    }

    /// Typed and switched away at once, inside the autosave's second: the keystroke wins.
    func testANewNoteTypedIntoIsKept() throws {
        launch()
        newNoteInBrowser()
        let editor = app.windows["All Notes"].textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "the new note has no editor")
        editor.click()
        app.typeText("x")
        selectKeeper()

        Thread.sleep(forTimeInterval: 2)
        let files = noteFiles().subtracting(keeperFiles)
        XCTAssertEqual(files.count, 2, "the typed note was discarded: \(noteFiles())")
        let text = try files.first { $0.hasSuffix(".txt") }.map {
            try String(contentsOf: notesFolder.appendingPathComponent($0), encoding: .utf8)
        }
        XCTAssertEqual(text, "x", "the typed note lost its text")
    }

    func testLaunchSweepsEmptyNotesAndKeepsWrittenOnes() throws {
        let empty = UUID()
        try seedNote(empty, contents: "")
        launch()
        XCTAssertEqual(noteFiles(), keeperFiles, "the empty note survived launch")
        XCTAssertFalse(app.staticTexts["New Note"].firstMatch.exists, "the empty note is still listed")
    }
}
