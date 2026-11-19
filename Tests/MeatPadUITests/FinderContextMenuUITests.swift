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
        print("FINDER_E2E clicked: Untitled.md exists=\(exists)")
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

    // MARK: - Helpers

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
        let started = Date()
        var attempts = 0
        var found = false
        while !found && Date().timeIntervalSince(started) < 90 {
            attempts += 1
            // Lower half, right of the sidebar: blank space away from the one file.
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.8)).rightClick()
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
