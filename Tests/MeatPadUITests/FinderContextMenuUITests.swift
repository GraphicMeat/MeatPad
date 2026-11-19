import AppKit
import XCTest

/// Drives the real Finder: MeatPad's Finder Sync extension (MeatPadFinder.appex) must add
/// its items to a folder window's right-click menu.
///
/// Needs the extension registered and enabled (`pluginkit -a` / `pluginkit -e use`), which
/// only `scripts/finder-e2e.sh` does, so the test skips unless the runner sees
/// `MEATPAD_FINDER_E2E=1` (export `TEST_RUNNER_MEATPAD_FINDER_E2E=1` in the shell).
final class FinderContextMenuUITests: XCTestCase {

    private var app: XCUIApplication!
    private let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
    /// Deleted wholesale in teardown; holds both `folder` and the storage root.
    private var sandbox = URL(fileURLWithPath: "/")
    /// The folder opened in Finder — its name is the Finder window's title.
    private var folder = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["MEATPAD_FINDER_E2E"] == "1" else {
            throw XCTSkip("needs the Finder extension enabled — run scripts/finder-e2e.sh")
        }

        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MeatPadUITests-\(UUID().uuidString)", isDirectory: true)
        folder = sandbox.appendingPathComponent(
            "FinderE2E-\(UUID().uuidString.prefix(8))", isDirectory: true
        )
        let storageRoot = sandbox.appendingPathComponent("Storage", isDirectory: true)
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        try files.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        try "one file\n".write(
            to: folder.appendingPathComponent("existing.md"), atomically: true, encoding: .utf8
        )

        // Launched before any Finder click: the launch persists `finder.token` (never passed
        // here as an argument — the extension reads the stored default, not our arguments).
        app = XCUIApplication()
        app.launchArguments = [
            "-meatpad.storageRootOverride", storageRoot.path,
            "-hasSeenFirstRunIntro", "YES",
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        if finder.exists {
            finder.typeKey(.escape, modifierFlags: [])
            let window = finder.windows[folder.lastPathComponent]
            if window.exists {
                window.buttons[XCUIIdentifierCloseWindow].click()
            }
        }
        app?.terminate()
        try? FileManager.default.removeItem(at: sandbox)
    }

    func testBlankAreaMenuOffersNewFileItems() throws {
        let window = try openFolderInFinder()
        let markdown = finder.menuItems["New Markdown File"]
        let text = finder.menuItems["New Text File"]
        let found = rightClickBlankArea(of: window, until: markdown)

        attach("menu-open")
        XCTAssertTrue(found, "\"New Markdown File\" never appeared in the blank-area menu")
        XCTAssertTrue(text.exists, "\"New Text File\" is missing from the blank-area menu")
        finder.typeKey(.escape, modifierFlags: [])

        // Informational only (Task 0 spike): does the item menu carry them too?
        let file = window.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'existing.md' OR value == 'existing.md'"))
            .firstMatch
        if file.waitForExistence(timeout: 5) {
            let frame = file.frame
            let point = CGPoint(x: frame.midX, y: frame.midY)
            window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: point.x - window.frame.minX, dy: point.y - window.frame.minY))
                .rightClick()
            let onItem = markdown.waitForExistence(timeout: 5)
            attach("item-menu")
            print("FINDER_E2E itemMenu found=\(onItem)")
            finder.typeKey(.escape, modifierFlags: [])
        } else {
            print("FINDER_E2E itemMenu file element not found")
        }
    }

    /// The whole feature through the real Finder: the click reaches the extension, the
    /// extension's URL reaches the app, and the app creates the file and opens it as a tab
    /// in a project window for that folder.
    func testClickingNewMarkdownFileCreatesAndOpensIt() throws {
        let window = try openFolderInFinder()
        let markdown = finder.menuItems["New Markdown File"]
        let found = rightClickBlankArea(of: window, until: markdown)
        attach("menu-before-click")
        XCTAssertTrue(found, "\"New Markdown File\" never appeared in the blank-area menu")

        markdown.click()
        let created = folder.appendingPathComponent("Untitled.md")
        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: created.path) && Date() < deadline {
            usleep(250_000)
        }
        let exists = FileManager.default.fileExists(atPath: created.path)
        // The extension sends the token the app persisted at launch (setUp), so the app must
        // act without asking. An unauthenticated request would sit behind a confirmation.
        let dialogs = app.dialogs.count, sheets = app.sheets.count
        let confirm = app.buttons["Create"].exists
        print("FINDER_E2E clicked: Untitled.md exists=\(exists) dialogs=\(dialogs) sheets=\(sheets) createButton=\(confirm)")
        XCTAssertEqual(dialogs, 0, "MeatPad showed a dialog after the Finder click — the token was not accepted")
        XCTAssertEqual(sheets, 0, "MeatPad showed a sheet after the Finder click")
        XCTAssertFalse(confirm, "MeatPad asked to confirm a request from its own extension")
        attach(exists ? "after-click" : "after-click-no-file")
        XCTAssertTrue(exists, "clicking \"New Markdown File\" did not create \(created.path)")

        let tabFound = app.staticTexts["tab-Untitled.md"].waitForExistence(timeout: 20)
        attach("meatpad-after-click")
        XCTAssertTrue(tabFound, "Untitled.md never opened as a tab in MeatPad")
        XCTAssertTrue(
            app.windows[folder.lastPathComponent].waitForExistence(timeout: 5),
            "MeatPad has no project window for \(folder.lastPathComponent)"
        )
    }

    /// Right-click on a folder item: the new file goes inside that folder, not beside it.
    func testClickingOnAFolderItemCreatesInsideIt() throws {
        let sub = try makeSubfolder()
        let window = try openFolderInFinder()
        let markdown = finder.menuItems["New Markdown File"]
        let subItem = finderItem("Sub", in: window)
        XCTAssertTrue(subItem.waitForExistence(timeout: 10), "no \"Sub\" item in the Finder window")

        let found = rightClick(until: markdown) { self.point(on: subItem, in: window) }
        attach("sub-item-menu")
        XCTAssertTrue(found, "\"New Markdown File\" never appeared in the menu of the Sub folder")
        markdown.click()

        let inside = sub.appendingPathComponent("Untitled.md")
        let exists = waitForFile(inside, timeout: 30)
        print("FINDER_E2E item-click: Sub/Untitled.md exists=\(exists)")
        attach(exists ? "sub-item-after-click" : "sub-item-after-click-no-file")
        XCTAssertTrue(exists, "clicking \"New Markdown File\" on Sub did not create \(inside.path)")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("Untitled.md").path),
            "the file was (also) created beside Sub instead of inside it"
        )
    }

    /// Blank-area right-click with a folder still selected: the window's folder is the target,
    /// never the selected folder.
    func testBlankAreaClickIgnoresASelectedFolder() throws {
        let sub = try makeSubfolder()
        let window = try openFolderInFinder()
        let markdown = finder.menuItems["New Markdown File"]
        // Wait for Finder to load the extension first, so the menu below is one right-click
        // made while Sub is selected, not one of several retries.
        XCTAssertTrue(rightClickBlankArea(of: window, until: markdown), "the extension's items never appeared")
        finder.typeKey(.escape, modifierFlags: [])
        sleep(1)

        let subItem = finderItem("Sub", in: window)
        XCTAssertTrue(subItem.waitForExistence(timeout: 10), "no \"Sub\" item in the Finder window")
        point(on: subItem, in: window).click()
        sleep(1)
        attach("sub-selected")

        window.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.8)).rightClick()
        let found = markdown.waitForExistence(timeout: 5)
        attach("blank-menu-with-sub-selected")
        XCTAssertTrue(found, "\"New Markdown File\" missing from the blank-area menu")
        markdown.click()

        let created = folder.appendingPathComponent("Untitled.md")
        let exists = waitForFile(created, timeout: 30)
        let inSub = ((try? FileManager.default.contentsOfDirectory(atPath: sub.path)) ?? [])
            .filter { $0 != ".DS_Store" }
        print("FINDER_E2E blank-click-with-selection: parent Untitled.md=\(exists) Sub contents=\(inSub)")
        attach("blank-after-click")
        XCTAssertTrue(exists, "the blank-area click did not create \(created.path)")
        XCTAssertEqual(inSub, [], "the blank-area click created the file inside the selected folder")
    }

    // MARK: - Helpers

    private func makeSubfolder() throws -> URL {
        let sub = folder.appendingPathComponent("Sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        return sub
    }

    /// An item in the Finder window by its name, in icon or list view.
    private func finderItem(_ name: String, in window: XCUIElement) -> XCUIElement {
        window.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR value == %@", name, name))
            .firstMatch
    }

    /// The centre of `element`, addressed through the window: Finder's items can report not
    /// hittable although a click there lands.
    private func point(on element: XCUIElement, in window: XCUIElement) -> XCUICoordinate {
        let frame = element.frame
        return window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX - window.frame.minX, dy: frame.midY - window.frame.minY))
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: url.path) && Date() < deadline {
            usleep(250_000)
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Opens `folder` in Finder and returns its window.
    private func openFolderInFinder() throws -> XCUIElement {
        print("FINDER_E2E folder=\(folder.path)")
        XCTAssertTrue(NSWorkspace.shared.open(folder), "Finder refused to open \(folder.path)")
        finder.activate()
        let window = finder.windows[folder.lastPathComponent]
        XCTAssertTrue(window.waitForExistence(timeout: 20), "no Finder window titled \(folder.lastPathComponent)")
        return window
    }

    /// Right-clicks blank space in `window` until `item` shows in the menu (left open) or 90 s
    /// pass. Finder may load the extension a few seconds after it is enabled: retry the
    /// right-click rather than fail on the first menu built without it.
    private func rightClickBlankArea(of window: XCUIElement, until item: XCUIElement) -> Bool {
        // Lower half, right of the sidebar: blank space away from the items.
        rightClick(until: item) { window.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.8)) }
    }

    /// Right-clicks `point()` until `item` shows in the menu (left open) or 90 s pass.
    private func rightClick(until item: XCUIElement, at point: () -> XCUICoordinate) -> Bool {
        let started = Date()
        var attempts = 0
        var found = false
        while !found && Date().timeIntervalSince(started) < 90 {
            attempts += 1
            point().rightClick()
            found = item.waitForExistence(timeout: 5)
            if !found {
                attach("menu-attempt-\(attempts)")
                finder.typeKey(.escape, modifierFlags: [])
                sleep(3)
            }
        }
        print("FINDER_E2E attempts=\(attempts) seconds=\(Int(Date().timeIntervalSince(started))) found=\(found)")
        return found
    }

    /// Whole-screen shot: the context menu is its own window, outside Finder's.
    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
