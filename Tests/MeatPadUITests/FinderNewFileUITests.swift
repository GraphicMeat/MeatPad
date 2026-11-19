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
    /// Pinned with `-finder.token` (argument domain, never persisted): a request carrying it
    /// is what the extension sends, so the app acts on it without asking.
    private static let testToken = String(repeating: "5eed7e57", count: 8)
    private static let wrongToken = String(repeating: "badc0ffe", count: 8)

    private var app: XCUIApplication!
    private let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
    /// Deleted wholesale in teardown; holds both `folder` and the storage root.
    private var sandbox = URL(fileURLWithPath: "/")
    /// Where new files are requested — its name is the project window's title.
    private var folder = URL(fileURLWithPath: "/")
    private let fm = FileManager.default
    /// Set by the tests that edit Settings ▸ Finder, so teardown resets it even after a failure.
    private var touchesFinderSettings = false

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
            "-finder.token", Self.testToken,
        ] + extraArguments
        app.launch()

        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
        XCTAssertEqual(
            instances.count, 1,
            "more than one MeatPad is running — quit the others and re-run: \(instances.compactMap { $0.bundleURL?.path })"
        )
    }

    override func tearDownWithError() throws {
        // The Settings tests write the app's real defaults domain. They press Reset to
        // Defaults themselves; this repeats it for a test that failed before getting there.
        if touchesFinderSettings, app?.state == .runningForeground || app?.state == .runningBackground {
            if openFinderSettings() {
                element("settings.finder.reset").click()
                print("FINDER_NEWFILE teardown: pressed Reset to Defaults")
            } else {
                print("FINDER_NEWFILE teardown: Settings ▸ Finder not reachable, no reset")
            }
        }
        if finder.exists {
            let window = finder.windows[folder.lastPathComponent]
            if window.exists { window.buttons[XCUIIdentifierCloseWindow].click() }
        }
        app?.terminate()
        // A Settings edit or reset is saved to the app's real defaults; don't leave one there.
        // `finder.token` is left alone: every launch here pins it with `-finder.token` (argument
        // domain), and the app never rewrites a usable value, so this class persists none — a
        // stored one belongs to someone else.
        UserDefaults(suiteName: Self.bundleID)?.removeObject(forKey: "finder.menu")
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
        // The Show in Finder branch really ran: Finder has a window on the folder.
        XCTAssertTrue(
            finder.windows[folder.lastPathComponent].waitForExistence(timeout: 20),
            "no Finder window for \(folder.lastPathComponent) — the file was not shown in Finder"
        )
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

    // MARK: - Unauthenticated requests

    func testATokenlessRequestAsksAndCancelCreatesNothing() throws {
        try launch(extraArguments: [])
        try send(request(dir: folder.path, ext: "md", token: nil))
        expectConfirmation("tokenless-confirmation")
        XCTAssertEqual(try folderContents(), [], "a file was created before the user answered")

        alertButton("Cancel").click()
        XCTAssertTrue(poll { !self.alertButton("Create").exists }, "the confirmation did not close on Cancel")
        sleep(2)
        attach("tokenless-cancelled")
        XCTAssertEqual(try folderContents(), [], "Cancel still created a file")
        XCTAssertFalse(app.windows[folder.lastPathComponent].exists, "Cancel still opened a project window")
    }

    func testATokenlessRequestConfirmedCreatesAndOpensTheFile() throws {
        try launch(extraArguments: [])
        try send(request(dir: folder.path, ext: "md", token: nil))
        expectConfirmation("tokenless-confirmation-before-create")
        XCTAssertEqual(try folderContents(), [], "a file was created before the user answered")

        alertButton("Create").click()
        let created = folder.appendingPathComponent("Untitled.md")
        XCTAssertTrue(waitForFile(created, timeout: 20), "Create did not create Untitled.md")
        XCTAssertTrue(tab("Untitled.md").waitForExistence(timeout: 20), "Untitled.md never opened as a tab")
        attach("tokenless-created")
    }

    func testAWrongTokenAsksAndCancelCreatesNothing() throws {
        try launch(extraArguments: [])
        try send(request(dir: folder.path, ext: "md", token: Self.wrongToken))
        expectConfirmation("wrong-token-confirmation")

        alertButton("Cancel").click()
        XCTAssertTrue(poll { !self.alertButton("Create").exists }, "the confirmation did not close on Cancel")
        sleep(2)
        XCTAssertEqual(try folderContents(), [], "Cancel still created a file")
        XCTAssertFalse(app.windows[folder.lastPathComponent].exists, "Cancel still opened a project window")
    }

    // MARK: - File ▸ New File… and Settings ▸ Finder

    func testFileMenuNewFileSavesIntoTheFocusedProjectAndOpensATab() throws {
        try launch(extraArguments: [])
        // Open With route: the folder becomes a project window.
        try send(folder)
        let window = app.windows[folder.lastPathComponent]
        XCTAssertTrue(window.waitForExistence(timeout: 20), "no project window for the folder")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).click()

        let fileMenu = app.menuBars.menuBarItems["File"]
        fileMenu.click()
        let item = fileMenu.menuItems["New File…"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the File menu has no New File… item")
        item.click()

        let save = app.buttons["Save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10), "New File… showed no save panel")
        attach("new-file-save-panel")
        // Accept the panel as offered: the project's root, "Untitled.md". A click, not Return:
        // the keystroke was once lost before the panel took key focus (1 run in 4 on the mini).
        save.click()

        let created = folder.appendingPathComponent("Untitled.md")
        XCTAssertTrue(waitForFile(created, timeout: 20), "Untitled.md was not saved into the project root")
        XCTAssertEqual(try Data(contentsOf: created), Data(), "the new file is not empty")
        XCTAssertTrue(tab("Untitled.md").waitForExistence(timeout: 20), "Untitled.md never opened as a tab")
        attach("new-file-opened")
    }

    func testFinderSettingsEditsReachTheNextRequest() throws {
        // A window in front, so the Settings shortcut has an app to go to. All Notes is not a
        // project window.
        try launch(extraArguments: ["-meatpad.revealBoard", "all"])
        touchesFinderSettings = true
        XCTAssertTrue(app.buttons["sidebar.newBoard"].firstMatch.waitForExistence(timeout: 20), "the browser never opened")
        XCTAssertTrue(openFinderSettings(), "Settings has no Finder tab")

        let picker = element("settings.finder.afterCreate")
        picker.click()
        let showInFinder = app.menuItems["Show in Finder"].firstMatch
        XCTAssertTrue(showInFinder.waitForExistence(timeout: 5), "After creating offers no Show in Finder")
        showInFinder.click()
        XCTAssertTrue(poll { "\(picker.value ?? "")" == "Show in Finder" }, "the picker did not switch: \(picker.value ?? "nil")")
        attach("settings-show-in-finder")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(poll { !picker.exists }, "Settings did not close")

        try send(request(dir: folder.path, ext: "md"))
        let created = folder.appendingPathComponent("Untitled.md")
        XCTAssertTrue(waitForFile(created, timeout: 20), "Untitled.md was never created")
        XCTAssertTrue(
            finder.windows[folder.lastPathComponent].waitForExistence(timeout: 20),
            "no Finder window for \(folder.lastPathComponent) — the Settings edit did not reach the request"
        )
        sleep(3)
        XCTAssertFalse(app.windows[folder.lastPathComponent].exists, "a project window opened despite Show in Finder")
        XCTAssertFalse(tab("Untitled.md").exists, "the file opened as a tab despite Show in Finder")

        XCTAssertTrue(openFinderSettings(), "could not reopen Settings ▸ Finder")
        element("settings.finder.reset").click()
        XCTAssertTrue(poll { "\(picker.value ?? "")" == "Open in MeatPad" }, "Reset left After creating at \(picker.value ?? "nil")")
    }

    func testFinderSettingsAddAndDeleteAFileType() throws {
        try launch(extraArguments: ["-meatpad.revealBoard", "all"])
        touchesFinderSettings = true
        XCTAssertTrue(app.buttons["sidebar.newBoard"].firstMatch.waitForExistence(timeout: 20), "the browser never opened")
        XCTAssertTrue(openFinderSettings(), "Settings has no Finder tab")

        let status = element("settings.finder.status")
        XCTAssertTrue(status.exists, "no extension status row")
        print("FINDER_NEWFILE status label=\(status.label) value=\(status.value ?? "nil")")
        XCTAssertTrue(element("settings.finder.openSystemSettings").exists, "no Open System Settings… button")
        XCTAssertEqual(rowTitles(), ["Markdown", "Text"], "the defaults are not Markdown and Text")

        element("settings.finder.add").click()
        let title = element("settings.finder.action.2.title")
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Add File Type added no third row")
        title.click()
        app.typeText("JSON")
        let ext = element("settings.finder.action.2.ext")
        ext.click()
        app.typeText("json")
        XCTAssertTrue(poll { self.rowTitles() == ["Markdown", "Text", "JSON"] }, "rows are \(rowTitles())")
        XCTAssertEqual("\(ext.value ?? "")", "json")
        attach("settings-finder-pane")

        element("settings.finder.action.2.delete").click()
        XCTAssertTrue(poll { self.rowTitles() == ["Markdown", "Text"] }, "deleting the third row left \(rowTitles())")
        // Delete a default too, so Reset has something to restore.
        element("settings.finder.action.0.delete").click()
        XCTAssertTrue(poll { self.rowTitles() == ["Text"] }, "deleting Markdown left \(rowTitles())")

        element("settings.finder.reset").click()
        XCTAssertTrue(poll { self.rowTitles() == ["Markdown", "Text"] }, "Reset to Defaults left \(rowTitles())")
        attach("settings-finder-after-reset")
    }

    // MARK: - Helpers

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The title field of every action row, in order (rows are numbered from 0 with no gaps).
    private func rowTitles() -> [String] {
        var titles: [String] = []
        while titles.count < 20 {
            let field = element("settings.finder.action.\(titles.count).title")
            guard field.exists else { break }
            titles.append("\(field.value ?? "")")
        }
        return titles
    }

    /// ⌘, then the Finder tab. True once the pane's After creating picker is on screen.
    @discardableResult
    private func openFinderSettings() -> Bool {
        app.activate()
        app.typeKey(",", modifierFlags: .command)
        let tab = element("settings-finder-tab")
        let byName = app.toolbars.buttons["Finder"].firstMatch
        guard tab.waitForExistence(timeout: 10) || byName.waitForExistence(timeout: 2) else { return false }
        (tab.exists ? tab : byName).click()
        return element("settings.finder.afterCreate").waitForExistence(timeout: 5)
    }

    private func poll(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(200_000)
        }
        return condition()
    }

    /// `token` defaults to the pinned one, i.e. a request as the extension sends it; nil sends
    /// none, as any other app or a web page would.
    private func request(dir: String, ext: String, token: String? = FinderNewFileUITests.testToken) -> URL {
        var components = URLComponents()
        components.scheme = "meatpad"
        components.host = "new-file"
        var items = [URLQueryItem(name: "dir", value: dir), URLQueryItem(name: "ext", value: ext)]
        if let token { items.append(URLQueryItem(name: "token", value: token)) }
        components.queryItems = items
        return components.url!
    }

    /// The confirmation alert's button `title` (NSAlert runs as an app-modal dialog).
    private func alertButton(_ title: String) -> XCUIElement {
        let inDialog = app.dialogs.buttons[title].firstMatch
        return inDialog.exists ? inDialog : app.buttons[title].firstMatch
    }

    /// Waits for the confirmation and checks it names the folder. Fails the test otherwise.
    private func expectConfirmation(_ name: String) {
        XCTAssertTrue(
            poll(timeout: 20) { self.alertButton("Create").exists },
            "no confirmation for an unauthenticated request: \(app.debugDescription)"
        )
        XCTAssertTrue(alertButton("Cancel").exists, "the confirmation has no Cancel")
        let naming = app.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@ OR label CONTAINS %@", "“\(folder.lastPathComponent)”", "“\(folder.lastPathComponent)”"
        )).firstMatch
        XCTAssertTrue(naming.exists, "the confirmation does not name \(folder.lastPathComponent)")
        attach(name)
    }

    /// Folder contents bar Finder's own litter.
    private func folderContents() throws -> [String] {
        try fm.contentsOfDirectory(atPath: folder.path).filter { $0 != ".DS_Store" }
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
