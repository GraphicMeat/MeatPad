import XCTest

/// Settings ▸ General line spacing for notes. The spacing is paragraph-style work inside
/// STTextView, which only shows up as the height the document lays out to — so a long note is
/// opened at 1× and at 2×, and the editor's height compared. Shots are written for a human.
final class NoteLineSpacingUITests: XCTestCase {

    private var app: XCUIApplication!
    private var storageRoot = URL(fileURLWithPath: "/")
    private let noteID = UUID()

    override func setUpWithError() throws {
        continueAfterFailure = false
        storageRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MeatPadUITests-\(UUID().uuidString)", isDirectory: true)
        let notes = storageRoot.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let sidecar = """
        {"id":"\(noteID.uuidString)","created":"2026-01-01T09:00:00Z","modified":"2026-01-01T09:00:00Z",\
        "cursor":0,"title":"Spacing"}
        """
        try Data(sidecar.utf8).write(to: notes.appendingPathComponent("\(noteID.uuidString).json"))
        let body = (["Spacing"] + (1...80).map { "line \($0)" }).joined(separator: "\n")
        try Data(body.utf8).write(to: notes.appendingPathComponent("\(noteID.uuidString).txt"))
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: storageRoot)
    }

    func testSpacingGrowsTheNote() {
        let single = editorHeight(lineSpacing: 1, shot: "note-line-spacing-1")
        app.terminate()
        let double = editorHeight(lineSpacing: 2, shot: "note-line-spacing-2")
        XCTAssertGreaterThan(double, single * 1.6, "2× spacing did not open the lines up (\(single) → \(double))")
    }

    private func editorHeight(lineSpacing: Double, shot: String) -> CGFloat {
        app = XCUIApplication()
        app.launchArguments = [
            "-meatpad.storageRootOverride", storageRoot.path,
            "-hasSeenFirstRunIntro", "YES",
            "-dockClickAction", "allNotes",
            "-notes.lineSpacing", String(lineSpacing),
        ]
        app.launch()
        let row = app.descendants(matching: .any).matching(identifier: "note-row-\(noteID.uuidString)").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the note never listed")
        row.click()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "selecting the note showed no editor")
        usleep(2_000_000)
        let data = app.windows.firstMatch.screenshot().pngRepresentation
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(shot).png")
        try? data.write(to: url)
        print("SHOT_WROTE \(url.path) \(data.count)")
        return editor.frame.height
    }
}
