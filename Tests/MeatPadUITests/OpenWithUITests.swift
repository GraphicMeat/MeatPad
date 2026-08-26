import AppKit
import XCTest

/// Finder's Open With, end to end — both halves of it.
///
/// The first half is whether MeatPad is in that menu at all: Launch Services only lists an
/// app for a file when the app's `CFBundleDocumentTypes` claim its type, which is checked
/// here by asking Launch Services the same question Finder asks (`urlsForApplications
/// (toOpen:)`), not by reading the Info.plist back.
///
/// The second half is what happens after the click, and it is the half that can silently
/// do nothing: files arrive as one `application(_:open:)` call and have to end up as tabs
/// in a project window rooted at their folder. Files are handed over exactly the way Finder
/// hands them over — `NSWorkspace.open(_:withApplicationAt:)` sends the already-running
/// instance the same `odoc` event — so the routing is really exercised, tab bar included.
///
/// Each run gets its own throwaway storage root (seeded on disk before launch, so the
/// override is honoured and the real notes store is never touched) and its own folder of
/// documents to open.
final class OpenWithUITests: XCTestCase {

    private static let bundleID = "com.thecoldzero.MeatPad"

    private var app: XCUIApplication!
    /// Deleted wholesale in teardown; holds both `folder` and the storage root.
    private var sandbox = URL(fileURLWithPath: "/")
    /// The folder handed to Finder — its name is the project window's title.
    private var folder = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        continueAfterFailure = false

        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MeatPadUITests-\(UUID().uuidString)", isDirectory: true)
        folder = sandbox.appendingPathComponent("Docs", isDirectory: true)
        let storageRoot = sandbox.appendingPathComponent("Storage", isDirectory: true)
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        // Must exist before launch: `NoteStore.defaultRoot` ignores an override path that
        // isn't a directory and would quietly use the real store instead.
        try files.createDirectory(at: storageRoot, withIntermediateDirectories: true)

        for name in ["alpha.md", "beta.md", "Makefile"] {
            try "contents of \(name)\n".write(
                to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8
            )
        }

        app = XCUIApplication()
        app.launchArguments = [
            "-meatpad.storageRootOverride", storageRoot.path,
            "-hasSeenFirstRunIntro", "YES",
        ]
        // No window opens by itself: a fresh storage root restores no session, which is
        // exactly the state Finder's Open With finds a running-but-idle MeatPad in.
        app.launch()

        // Fails here, not confusingly three asserts later: Launch Services routes by bundle
        // identity, so a second MeatPad (an installed release on the same machine) can be
        // handed the files instead of the app under test.
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
        XCTAssertEqual(
            instances.count, 1,
            "more than one MeatPad is running — quit the others and re-run: \(instances.compactMap { $0.bundleURL?.path })"
        )
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: sandbox)
    }

    // MARK: - In the menu at all

    /// The user-visible feature: MeatPad shows up under Finder ▸ Open With. Asked per type
    /// rather than once, because they reach the app through different claims — `.md` and
    /// `.txt` through the text UTIs, `.json`/`.sh` through their own, and an extension-less
    /// `Makefile` only through `public.data`, the claim easiest to drop by accident.
    func testLaunchServicesOffersMeatPadForEveryFileTypeItClaims() throws {
        for name in ["alpha.md", "Makefile", "notes.txt", "data.json", "build.sh", "page.xml"] {
            let url = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                try "x\n".write(to: url, atomically: true, encoding: .utf8)
            }
            // Compared by bundle identifier, not path: Launch Services may hand back
            // another registered copy of MeatPad (an installed release on the same
            // machine), and any copy it lists had to have declared the type to be there.
            let listed = NSWorkspace.shared.urlsForApplications(toOpen: url)
                .compactMap { Bundle(url: $0)?.bundleIdentifier }
            XCTAssertTrue(
                listed.contains(Self.bundleID),
                "\(name): MeatPad is not offered for this file — apps offered: \(listed)"
            )
        }
    }

    // MARK: - What the click does

    func testOpeningAFileShowsItAsATabInAProjectWindowForItsFolder() throws {
        try openWithFinder([folder.appendingPathComponent("alpha.md")])

        XCTAssertTrue(tab("alpha.md").waitForExistence(timeout: 20), "alpha.md never opened as a tab")
        XCTAssertTrue(app.windows["Docs"].waitForExistence(timeout: 5), "no project window for the file's folder")
    }

    /// An extension-less file is the reason `public.data` is claimed; opening one proves
    /// the claim goes somewhere rather than just decorating the menu.
    func testOpeningAnExtensionlessFileOpensItToo() throws {
        try openWithFinder([folder.appendingPathComponent("Makefile")])

        XCTAssertTrue(tab("Makefile").waitForExistence(timeout: 20), "Makefile never opened as a tab")
    }

    /// Finder hands a multi-selection over in a single call. Every file has to survive it —
    /// the stash they wait in is filled before the first window opens precisely because the
    /// window's view model can consume it synchronously, mid-call.
    func testAMultiSelectionOpensEveryFileAsATab() throws {
        try openWithFinder([
            folder.appendingPathComponent("alpha.md"),
            folder.appendingPathComponent("beta.md"),
        ])

        XCTAssertTrue(tab("alpha.md").waitForExistence(timeout: 20), "alpha.md never opened as a tab")
        XCTAssertTrue(tab("beta.md").waitForExistence(timeout: 20), "beta.md never opened as a tab")
    }

    /// The regression this feature is most likely to hit in real use: the project window is
    /// already open, so `openWindow(value:)` only re-focuses it and the second file used to
    /// be dropped on the floor. Both tabs, one window.
    func testASecondFileJoinsTheWindowThatIsAlreadyOpen() throws {
        try openWithFinder([folder.appendingPathComponent("alpha.md")])
        XCTAssertTrue(tab("alpha.md").waitForExistence(timeout: 20), "alpha.md never opened as a tab")

        try openWithFinder([folder.appendingPathComponent("beta.md")])
        XCTAssertTrue(tab("beta.md").waitForExistence(timeout: 20), "beta.md never opened as a tab")

        XCTAssertTrue(tab("alpha.md").exists, "opening the second file closed the first one's tab")
        XCTAssertEqual(app.windows.count, 1, "the second file opened a second window instead of a tab")
    }

    /// Dropping a folder on the app is the other half of the same call. It opens as the
    /// project itself — nothing gets opened as a tab, and the folder must never be mistaken
    /// for a file (which would open its *parent* with the folder sitting in the tab bar).
    func testOpeningAFolderOpensItAsTheProjectWithNoTabs() throws {
        try openWithFinder([folder])

        XCTAssertTrue(app.windows["Docs"].waitForExistence(timeout: 20), "the folder didn't open as a project")
        XCTAssertTrue(app.staticTexts["alpha.md"].waitForExistence(timeout: 10), "the file tree is empty")
        XCTAssertFalse(tab("alpha.md").exists, "a folder open should not pre-open any tab")
        XCTAssertFalse(tab("Docs").exists, "the folder itself was opened as a tab")
    }

    // MARK: - Helpers

    /// The tab bar's own label for `name` — the file tree shows the same filenames, so the
    /// identifier (see `TabBarView`) is what distinguishes "open as a tab" from "listed".
    private func tab(_ name: String) -> XCUIElement {
        app.staticTexts["tab-\(name)"]
    }

    /// Hands `urls` to the running app the way Finder does. The most recently launched copy
    /// is the one this test launched, in case another MeatPad happens to be running.
    private func openWithFinder(_ urls: [URL]) throws {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
            .max { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
        let bundleURL = try XCTUnwrap(running?.bundleURL, "the app under test isn't running")

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let opened = expectation(description: "Launch Services opened \(urls.count) file(s)")
        NSWorkspace.shared.open(urls, withApplicationAt: bundleURL, configuration: configuration) { _, error in
            XCTAssertNil(error, "Launch Services refused to open the files")
            opened.fulfill()
        }
        wait(for: [opened], timeout: 30)
    }
}
