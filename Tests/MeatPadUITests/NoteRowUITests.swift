import XCTest

/// Every All Notes row is tall enough for its title and its date line. Rows were reported coming
/// up a single line tall: the date clipped away and the next row's title drawn where it would be.
final class NoteRowUITests: XCTestCase {

    private var app: XCUIApplication!
    private var storageRoot = URL(fileURLWithPath: "/")
    /// Title and days since last edit; distinct ages give each row a distinct date label. Long
    /// titles that truncate, like the rows in the report.
    private let seeded: [(title: String, daysAgo: Double)] = [
        ("A few gentle design thoughts about spacing and rhythm in long lists", 3),
        ("https://www.pixelresort.example.com/articles/a-long-path-that-truncates-in-the-list", 5),
        ("Gamma", 9),
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
        storageRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MeatPadUITests-\(UUID().uuidString)", isDirectory: true)
        let notes = storageRoot.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter()
        for note in seeded {
            let id = UUID().uuidString
            let stamp = iso.string(from: Date().addingTimeInterval(-note.daysAgo * 86_400))
            let sidecar = """
            {"id":"\(id)","created":"\(stamp)","modified":"\(stamp)","cursor":0,"title":"\(note.title)"}
            """
            try Data(sidecar.utf8).write(to: notes.appendingPathComponent("\(id).json"))
            try Data("\(note.title)\nbody".utf8).write(to: notes.appendingPathComponent("\(id).txt"))
        }
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
        assertRowsHoldTwoLines([("New Note", "now")] + seededLines())
    }

    func testListedRowsHoldTitleAndDate() {
        XCTAssertTrue(app.windows["All Notes"].waitForExistence(timeout: 20), "no All Notes window")
        XCTAssertTrue(app.staticTexts["Gamma"].firstMatch.waitForExistence(timeout: 10), "seeded notes never listed")
        assertRowsHoldTwoLines(seededLines())
    }

    /// A reopened window lays its list out again; so do notes arriving one after another.
    func testRowsHoldTwoLinesAfterReopenAndNewNotes() {
        XCTAssertTrue(app.windows["All Notes"].waitForExistence(timeout: 20), "no All Notes window")
        for _ in 0..<3 { app.typeKey("n", modifierFlags: [.command, .option]) }
        XCTAssertTrue(app.staticTexts["New Note"].firstMatch.waitForExistence(timeout: 5), "⌘⌥N listed no new note")
        app.typeKey("w", modifierFlags: .command)
        app.typeKey("l", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.windows["All Notes"].waitForExistence(timeout: 10), "⌘⇧L did not reopen All Notes")
        XCTAssertTrue(app.staticTexts["Gamma"].firstMatch.waitForExistence(timeout: 10), "seeded notes never listed")
        assertRowsHoldTwoLines(seededLines())
    }

    private func seededLines() -> [(title: String, date: String)] {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return seeded.map { ($0.title, formatter.localizedString(for: Date().addingTimeInterval(-$0.daysAgo * 86_400),
                                                                 relativeTo: Date())) }
    }

    /// Each title sits above its own date, and the next row's title starts below that date: a
    /// one-line row puts the next title on top of the date it clipped.
    private func assertRowsHoldTwoLines(_ rows: [(title: String, date: String)],
                                        file: StaticString = #filePath, line: UInt = #line) {
        let frames = rows.map { row -> (title: CGRect, date: CGRect) in
            let title = app.staticTexts[row.title].firstMatch
            let date = app.staticTexts[row.date].firstMatch
            XCTAssertTrue(title.exists && date.exists, "row \(row.title) / \(row.date) not found", file: file, line: line)
            return (title.frame, date.frame)
        }.sorted { $0.title.minY < $1.title.minY }
        print("ROW_PITCH \(zip(frames, frames.dropFirst()).map { $1.title.minY - $0.title.minY })")
        for (index, row) in frames.enumerated() {
            XCTAssertGreaterThanOrEqual(row.date.minY, row.title.maxY - 1,
                                        "a date line overlaps its title: \(frames)", file: file, line: line)
            if index + 1 < frames.count {
                XCTAssertGreaterThanOrEqual(frames[index + 1].title.minY, row.date.maxY - 1,
                                            "a row overlaps the date line above it: \(frames)", file: file, line: line)
            }
        }
        let data = app.windows["All Notes"].screenshot().pngRepresentation
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("note-rows.png")
        try? data.write(to: url)
        print("SHOT_WROTE \(url.path) \(data.count)")
    }
}
