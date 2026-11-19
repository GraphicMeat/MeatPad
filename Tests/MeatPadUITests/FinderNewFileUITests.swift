import AppKit
import XCTest

/// The app half of Finder's "New … File": the Finder Sync extension only opens
/// `meatpad://new-file?dir=…&ext=…`, and everything after that — the file on disk, never
/// overwriting, opening it as a tab or revealing it in Finder, refusing junk — happens here.
///
/// Requests are sent the way the extension sends them, as a URL handed to the running app
/// through Launch Services, aimed at the copy this test launched (another registered
/// MeatPad must not take the scheme). The URL is built by hand: this bundle does not link
/// MeatPadKit, and a hand-built URL is also what any outside caller would send.
final class FinderNewFileUITests: XCTestCase {

    private static let bundleID = "com.thecoldzero.MeatPad"

    private var app: XCUIApplication!
    private let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
    /// Deleted wholesale in teardown; holds both `folder` and the storage root.
    private var sandbox = URL(fileURLWithPath: "/")
    /// Where new files are requested — its name is the project window's title.
    private var folder = URL(fileURLWithPath: "/")
    private let fm = FileManager.default

    private func launch(extraArguments: [String]) throws {
        continueAfterFailure = false

        sandbox = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("MeatPadUITests-\(UUID().uuidString)", isDirectory: true)
        folder = sandbox.appendingPathComponent("NewFiles-\(UUID().uuidString.prefix(6))", isDirectory: true)
        let storageRoot = sandbox.appendingPathComponent("Storage", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        // Must exist before launch: `NoteStore.defaultRoot` ignores an override path that
        // isn't a directory and would quietly use the real store instead.
        try fm.createDirectory(at: storageRoot, withIntermediateDirectories: true)

        app = XCUIApplication()
        app.launchArguments = [
            "-meatpad.storageRootOverride", storageRoot.path,
            "-hasSeenFirstRunIntro", "YES",
        ] + extraArguments
        app.launch()

        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
        XCTAssertEqual(
            instances.count, 1,
            "more than one MeatPad is running — quit the others and re-run: \(instances.compactMap { $0.bundleURL?.path })"
        )
    }

    override func tearDownWithError() throws {
        if finder.exists {
            let window = finder.windows[folder.lastPathComponent]
            if window.exists { window.buttons[XCUIIdentifierCloseWindow].click() }
        }
        app?.terminate()
        try? fm.removeItem(at: sandbox)
    }

    // MARK: - Tests

    func testNewFileURLCreatesUntitledMarkdownAndOpensItAsATab() throws {
        try launch(extraArguments: [])
        try send(request(dir: folder.path, ext: "md"))

        let created = folder.appendingPathComponent("Untitled.md")
        XCTAssertTrue(waitForFile(created, timeout: 20), "Untitled.md was never created")
        XCTAssertEqual(try Data(contentsOf: created), Data(), "the new file is not empty")
        XCTAssertTrue(tab("Untitled.md").waitForExistence(timeout: 20), "Untitled.md never opened as a tab")
        XCTAssertTrue(app.windows[folder.lastPathComponent].waitForExistence(timeout: 5), "no project window for the folder")
        attach("opened-as-tab")
    }

    func testASecondRequestNeverOverwrites() throws {
        try launch(extraArguments: [])
        try send(request(dir: folder.path, ext: "md"))
        let first = folder.appendingPathComponent("Untitled.md")
        XCTAssertTrue(waitForFile(first, timeout: 20), "Untitled.md was never created")
        try "keep".write(to: first, atomically: false, encoding: .utf8)

        try send(request(dir: folder.path, ext: "md"))
        let second = folder.appendingPathComponent("Untitled 2.md")
        XCTAssertTrue(waitForFile(second, timeout: 20), "the second request did not create Untitled 2.md")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "keep", "the first file was overwritten")
        attach("second-request")
    }

    func testShowInFinderSettingCreatesTheFileWithoutAProjectWindow() throws {
        let json = #"{"afterCreate":"showInFinder"}"#
        // An argument value is parsed as a property list, and bare JSON isn't one — the whole
        // value is silently dropped. As a quoted plist string it arrives intact.
        let quoted = "\"" + json.replacingOccurrences(of: "\"", with: "\\\"") + "\""
        try launch(extraArguments: ["-finder.menu", quoted])

        try send(request(dir: folder.path, ext: "txt"))
        let created = folder.appendingPathComponent("Untitled.txt")
        XCTAssertTrue(waitForFile(created, timeout: 20), "Untitled.txt was never created")
        // Only meaningful once the file exists: the request was handled, and handled this way.
        sleep(3)
        attach("show-in-finder")
        XCTAssertFalse(app.windows[folder.lastPathComponent].exists, "a project window opened despite Show in Finder")
        XCTAssertFalse(tab("Untitled.txt").exists, "the file opened as a tab despite Show in Finder")
    }

    func testAMalformedRequestCreatesNothing() throws {
        try launch(extraArguments: [])
        let before = try fm.contentsOfDirectory(atPath: folder.path)

        try send(request(dir: "relative", ext: "md"))
        try send(request(dir: folder.path, ext: "a/b"))
        sleep(2)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: folder.path), before, "a malformed request created something")
        XCTAssertFalse(fm.fileExists(atPath: folder.appendingPathComponent("a").path))

        // Positive control: the same channel does work, so the silence above means "rejected".
        try send(request(dir: folder.path, ext: "md"))
        XCTAssertTrue(
            waitForFile(folder.appendingPathComponent("Untitled.md"), timeout: 20),
            "positive control: a valid request did not create Untitled.md"
        )
        attach("malformed-then-valid")
    }

    // MARK: - Helpers

    private func request(dir: String, ext: String) -> URL {
        var components = URLComponents()
        components.scheme = "meatpad"
        components.host = "new-file"
        components.queryItems = [URLQueryItem(name: "dir", value: dir), URLQueryItem(name: "ext", value: ext)]
        return components.url!
    }

    /// Hands `url` to the copy of MeatPad this test launched, as Launch Services would.
    private func send(_ url: URL) throws {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
            .max { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
        let bundleURL = try XCTUnwrap(running?.bundleURL, "the app under test isn't running")

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let opened = expectation(description: "Launch Services delivered \(url.absoluteString)")
        NSWorkspace.shared.open([url], withApplicationAt: bundleURL, configuration: configuration) { _, error in
            XCTAssertNil(error, "Launch Services refused to deliver \(url.absoluteString)")
            opened.fulfill()
        }
        wait(for: [opened], timeout: 30)
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if fm.fileExists(atPath: url.path) { return true }
            usleep(200_000)
        }
        return fm.fileExists(atPath: url.path)
    }

    /// The tab bar's own label for `name` (see `TabBarView`); the file tree shows the same text.
    private func tab(_ name: String) -> XCUIElement {
        app.staticTexts["tab-\(name)"]
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
