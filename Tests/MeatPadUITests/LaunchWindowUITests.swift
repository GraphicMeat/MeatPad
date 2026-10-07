import AppKit
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
        XCTAssertFalse(app.windows["New Note"].exists, "launch opened a new note")
    }

    /// A Dock click while windows are open brings them forward and opens nothing: no blank
    /// "Note" window, no new note. Reported on macOS 27; on macOS 26 (the test box) the click never
    /// misbehaved, so this can't go red there — it guards the contract. A Dock click on a running
    /// app is a reopen event, which Launch Services sends when asked to open the app again.
    func testDockReopenWithWindowsOpensNoNoteWindow() throws {
        XCTAssertTrue(app.windows["All Notes"].waitForExistence(timeout: 20), "launch opened no All Notes window")
        let notesBefore = noteFiles()

        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.thecoldzero.MeatPad")
            .max { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
        let bundleURL = try XCTUnwrap(running?.bundleURL, "the app under test isn't running")
        let reopened = expectation(description: "Launch Services reopened the app")
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            XCTAssertNil(error, "Launch Services refused to reopen the app")
            reopened.fulfill()
        }
        wait(for: [reopened], timeout: 20)
        // Give a stray window the time it would need to show up.
        Thread.sleep(forTimeInterval: 3)

        XCTAssertEqual(app.windows.allElementsBoundByIndex.map(\.title), ["All Notes"],
                       "the reopen changed the set of windows")
        XCTAssertEqual(noteFiles(), notesBefore, "the reopen created a note")
    }

    /// The notes on disk. No `Notes/` folder yet is no notes; `.trash` and the like aren't notes.
    private func noteFiles() -> Set<String> {
        let folder = storageRoot.appendingPathComponent("Notes", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(names.filter { $0.hasSuffix(".json") })
    }
}
