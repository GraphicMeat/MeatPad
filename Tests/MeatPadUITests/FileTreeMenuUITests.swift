import AppKit
import XCTest

/// The project sidebar's right-click menu, end to end: the real menu in the real app, driven by
/// real right-clicks, with the results checked on disk and on the system pasteboard — the two
/// places a menu that merely *looks* right would be caught out.
///
/// Each run gets a throwaway storage root and a throwaway project folder; nothing touches the
/// user's notes or files. The folder is handed over the way Finder hands it (`odoc`), which
/// opens it as a project window titled after the folder.
class FileTreeMenuUITestCase: XCTestCase {

    static let bundleID = "com.thecoldzero.MeatPad"

    var app: XCUIApplication!
    /// Deleted wholesale in teardown; holds the project and the storage root.
    var sandbox = URL(fileURLWithPath: "/")
    /// The project folder — its name is the window title.
    var project = URL(fileURLWithPath: "/")
    let fm = FileManager.default

    /// Extra launch arguments, for tests that seed a preference (`-fileTree.menu '{…}'`).
    var extraLaunchArguments: [String] { [] }

    override func setUpWithError() throws {
        continueAfterFailure = false

        // /private/var, not /var: the app standardizes paths, and the Copy Path assertions
        // compare against what it actually copies.
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("MeatPadUITests-\(UUID().uuidString)", isDirectory: true)
        project = sandbox.appendingPathComponent("Proj", isDirectory: true)
        let storageRoot = sandbox.appendingPathComponent("Storage", isDirectory: true)
        try fm.createDirectory(at: project.appendingPathComponent("sub", isDirectory: true), withIntermediateDirectories: true)
        // Must exist before launch: an override that isn't a directory is quietly ignored.
        try fm.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        for name in ["alpha.txt", "beta.txt"] {
            try "contents of \(name)\n".write(to: project.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try "inner\n".write(to: project.appendingPathComponent("sub/inner.txt"), atomically: true, encoding: .utf8)

        app = XCUIApplication()
        app.launchArguments = [
            "-meatpad.storageRootOverride", storageRoot.path,
            "-hasSeenFirstRunIntro", "YES",
            "-project.uiScale", "1",
        ] + extraLaunchArguments
        app.launch()

        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
        XCTAssertEqual(
            instances.count, 1,
            "more than one MeatPad is running — quit the others and re-run: \(instances.compactMap { $0.bundleURL?.path })"
        )
        try openProject()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try? fm.removeItem(at: sandbox)
        // Zoom is saved to the app's real defaults when changed; don't leave a test's zoom there.
        UserDefaults(suiteName: Self.bundleID)?.removeObject(forKey: "project.uiScale")
    }

    // MARK: - Helpers

    private func openProject() throws {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
            .max { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
        let bundleURL = try XCTUnwrap(running?.bundleURL, "the app under test isn't running")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let opened = expectation(description: "Launch Services opened the project")
        NSWorkspace.shared.open([project], withApplicationAt: bundleURL, configuration: configuration) { _, error in
            XCTAssertNil(error, "Launch Services refused to open the folder")
            opened.fulfill()
        }
        wait(for: [opened], timeout: 30)
        XCTAssertTrue(app.windows["Proj"].waitForExistence(timeout: 20), "the folder didn't open as a project")
        XCTAssertTrue(row("alpha.txt").waitForExistence(timeout: 10), "the file tree is empty")
    }

    /// A file-tree row, by its name (tabs carry `tab-` identifiers, so there is no clash). Any
    /// element type: a folder row with a disclosure triangle isn't a plain static text.
    func row(_ name: String) -> XCUIElement {
        // By label: the row's text is labelled with the name, while a tab only carries it as its
        // value — so once a file is open, a name match on "any" would pick the tab instead.
        // Any element type: a folder row (with its disclosure triangle) isn't a plain static text.
        app.windows["Proj"].descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", name)).firstMatch
    }

    /// A folder's disclosure triangle: the one level with its row. Not `firstMatch`: the project's
    /// root row has one too, and it comes first.
    func chevron(_ name: String) -> XCUIElement { chevron(atY: row(name).frame.midY) }

    func chevron(atY y: CGFloat) -> XCUIElement {
        app.windows["Proj"].disclosureTriangles.allElementsBoundByIndex
            .min { abs($0.frame.midY - y) < abs($1.frame.midY - y) }
            ?? app.windows["Proj"].disclosureTriangles.firstMatch
    }

    /// A folder's icon: 8 points past the right edge of its chevron, at the row's height — on the
    /// icon and clear of the chevron's own hit area, so a click here that folds the folder proves
    /// the icon does it. (A fixed distance from the sidebar's edge lands on the chevron's edge at
    /// the top level and inside it one level down.)
    func folderIcon(atY y: CGFloat) -> XCUICoordinate {
        let window = app.windows["Proj"].frame
        let triangle = chevron(atY: y).frame
        XCTAssertGreaterThan(triangle.width, 0, "no chevron level with y = \(y)")
        return app.windows["Proj"].coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: triangle.maxX + 8 - window.minX, dy: y - window.minY))
    }

    /// The right-click menu — not the menu bar's. `app.menus.firstMatch` is the Apple menu.
    var contextMenu: XCUIElement {
        app.menus.containing(.menuItem, identifier: "Reveal in Finder").firstMatch
    }

    /// Right-clicks `name` and waits for the menu. On the mini the first right-click on a row is
    /// sometimes swallowed, and now and then a menu closes again right after it opens, so the
    /// click is retried (up to 3 times) until a menu is open and has stayed open for a moment.
    @discardableResult
    func openMenu(on name: String) -> XCUIElement {
        openMenu(onElement: row(name), named: name)
    }

    /// Right-clicks a row found some other way than by its name (the root, by identifier).
    @discardableResult
    func openMenu(onElement target: XCUIElement, named name: String = "the row") -> XCUIElement {
        XCTAssertTrue(target.waitForExistence(timeout: 10), "no row named \(name)")
        let menu = contextMenu
        for _ in 0..<3 {
            // By coordinate: XCUITest can call a row "not hittable" (e.g. zoomed) though a real click lands.
            target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
            if menu.waitForExistence(timeout: 3) {
                Thread.sleep(forTimeInterval: 0.5)
                if menu.exists { return menu }
            }
        }
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "right-clicking \(name) opened no menu")
        return menu
    }

    /// A menu item by its title. An item with a second line exposes it as "Title, second line",
    /// so a plain `menuItems["Copy Path"]` would miss it — and "Copy" must not match "Copy Path".
    func menuItem(_ title: String, in menu: XCUIElement) -> XCUIElement {
        menu.menuItems
            .matching(NSPredicate(format: "title == %@ OR title BEGINSWITH %@", title, title + ", "))
            .firstMatch
    }

    func choose(_ item: String, on name: String) {
        // A menu that closed between opening and the lookup is reopened (twice at most) before
        // the assertion below calls the item missing.
        var entry = menuItem(item, in: openMenu(on: name))
        for _ in 0..<2 where !entry.waitForExistence(timeout: 3) {
            entry = menuItem(item, in: openMenu(on: name))
        }
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "no “\(item)” in the menu for \(name)")
        entry.click()
    }

    /// Titles of the open menu's items, top to bottom, with "|" standing for a separator. A second
    /// line ("Copy Path, /a/b") is cut off the title — `testCopyPath…SecondLine` checks those.
    /// The accessibility tree ends every NSMenu with one extra empty entry that isn't ours;
    /// "no separator at the ends" is proven on the model in `FileTreeMenuModelTests`.
    func menuLayout(_ menu: XCUIElement) -> [String] {
        var layout = menu.menuItems.allElementsBoundByIndex.map { item -> String in
            item.title.isEmpty ? "|" : (item.title.components(separatedBy: ", ").first ?? item.title)
        }
        if layout.last == "|" { layout.removeLast() }
        return layout
    }

    func exists(_ relative: String) -> Bool {
        fm.fileExists(atPath: project.appendingPathComponent(relative).path)
    }

    /// Polls `condition` — disk changes land a beat after the click, via the file watcher.
    func eventually(_ message: String, timeout: TimeInterval = 10, _ condition: () -> Bool,
                    file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTFail(message, file: file, line: line)
    }

    func typeName(_ name: String) {
        let field = app.textFields["namePrompt.name"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no name sheet opened")
        app.typeText(name)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "the name sheet stayed open")
    }
}

final class FileTreeMenuUITests: FileTreeMenuUITestCase {

    // MARK: - What the menu offers

    func testFileMenuHasEveryVSCodeItemInOrderWithSeparators() throws {
        let menu = openMenu(on: "alpha.txt")
        XCTAssertEqual(menuLayout(menu), [
            "New File…", "New Folder…", "|",
            "Reveal in Finder", "Open in Preview", "Open in Terminal", "Open in MeatPad Terminal", "|",
            "Find in Folder…", "|",
            "Cut", "Copy", "Paste", "|",
            "Copy Path", "Copy Relative Path", "|",
            "Rename…", "Delete",
        ])
    }

    func testFolderMenuHasNoOpenInPreview() throws {
        let menu = openMenu(on: "sub")
        XCTAssertTrue(menuItem("Open in Terminal", in: menu).exists)
        XCTAssertFalse(menuItem("Open in Preview", in: menu).exists, "Preview was offered for a folder")
    }

    func testRightClickedRowIsHighlightedOnlyWhileItsMenuIsOpen() throws {
        func isHighlighted(_ name: String) -> Bool { (row(name).value as? String) == "Context menu open" }

        openMenu(on: "beta.txt")
        eventually("the right-clicked row wasn't highlighted") { isHighlighted("beta.txt") }
        XCTAssertFalse(isHighlighted("alpha.txt"), "a row that wasn't right-clicked is highlighted too")

        app.typeKey(.escape, modifierFlags: [])
        eventually("the highlight stayed after the menu closed") { !isHighlighted("beta.txt") }
    }

    /// Left-click selects: the clicked row is lit, and only that one.
    func testLeftClickedRowIsHighlightedAndTheOneBeforeIsNot() throws {
        func value(_ name: String) -> String { (row(name).value as? String) ?? "" }

        row("beta.txt").click()
        eventually("the clicked row wasn't highlighted") { value("beta.txt") == "Selected" }

        row("alpha.txt").click()
        eventually("the newly clicked row wasn't highlighted") { value("alpha.txt") == "Selected" }
        XCTAssertNotEqual(value("beta.txt"), "Selected", "the previous row stayed highlighted")
    }

    /// A point on a folder's row, `dx` points from the sidebar's left edge, at the row's height.
    /// Computed from the outline and the row's frames rather than from the name's own element:
    /// a disclosure row doesn't expose its name as a plain static text.
    private func pointOnRow(_ name: String, fromLeft dx: CGFloat) -> XCUICoordinate {
        let window = app.windows["Proj"].frame
        let outline = app.windows["Proj"].outlines.firstMatch.frame
        let row = self.row(name).frame
        return app.windows["Proj"].coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: outline.minX + dx - window.minX, dy: row.midY - window.minY))
    }

    private func folderIcon(_ name: String) -> XCUICoordinate { folderIcon(atY: row(name).frame.midY) }

    /// Clicking a folder's icon folds and unfolds it, like its chevron.
    func testClickingAFolderIconUnfoldsAndFoldsIt() throws {
        XCTAssertFalse(row("inner.txt").exists, "the folder starts unfolded")
        folderIcon("sub").click()
        XCTAssertTrue(row("inner.txt").waitForExistence(timeout: 5), "clicking the folder icon didn't unfold it")
        folderIcon("sub").click()
        XCTAssertTrue(row("inner.txt").waitForNonExistence(timeout: 5), "clicking the icon again didn't fold it")
    }

    /// The name only selects: it must not fold or unfold.
    func testClickingAFolderNameSelectsItWithoutFolding() throws {
        row("sub").click()
        eventually("the folder wasn't selected") { (self.row("sub").value as? String) == "Selected" }
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertFalse(row("inner.txt").exists, "clicking the folder's name unfolded it")
    }

    /// Neither does the empty space to the right of the name.
    func testClickingTheEmptySpaceBesideAFolderNameSelectsItWithoutFolding() throws {
        pointOnRow("sub", fromLeft: 240).click()   // well to the right of the name, still on the row
        eventually("the folder wasn't selected") { (self.row("sub").value as? String) == "Selected" }
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertFalse(row("inner.txt").exists, "clicking beside the folder's name unfolded it")
    }

    func testTheChevronStillUnfoldsAndFoldsTheFolder() throws {
        let triangle = chevron("sub")
        XCTAssertTrue(triangle.waitForExistence(timeout: 10), "no chevron on the folder row")
        triangle.click()
        XCTAssertTrue(row("inner.txt").waitForExistence(timeout: 5), "the chevron didn't unfold the folder")
        triangle.click()
        XCTAssertTrue(row("inner.txt").waitForNonExistence(timeout: 5), "the chevron didn't fold it again")
    }

    func testUnfoldingAFolderKeepsItOpenAcrossARescan() throws {
        folderIcon("sub").click()
        XCTAssertTrue(row("inner.txt").waitForExistence(timeout: 5))
        // A change on disk triggers a rescan, which replaces the whole tree.
        try "x".write(to: project.appendingPathComponent("gamma.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(row("gamma.txt").waitForExistence(timeout: 15), "the new file never showed")
        XCTAssertTrue(row("inner.txt").exists, "the rescan folded the open folder back up")
    }

    func testFolderRowsAreHighlightedToo() throws {
        row("sub").click()
        eventually("a clicked folder wasn't highlighted") { (self.row("sub").value as? String) == "Selected" }
    }

    func testSwitchingTabsMovesTheHighlightToThatFile() throws {
        row("alpha.txt").click()
        XCTAssertTrue(app.staticTexts["tab-alpha.txt"].firstMatch.waitForExistence(timeout: 10))
        row("beta.txt").click()
        XCTAssertTrue(app.staticTexts["tab-beta.txt"].firstMatch.waitForExistence(timeout: 10))

        app.staticTexts["tab-alpha.txt"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        eventually("the tree didn't follow the active tab") { (self.row("alpha.txt").value as? String) == "Selected" }
        XCTAssertNotEqual(row("beta.txt").value as? String, "Selected")
    }

    func testPasteIsDisabledWhenTheClipboardHasNoFiles() throws {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("just text", forType: .string)
        let menu = openMenu(on: "alpha.txt")
        XCTAssertFalse(menuItem("Paste", in: menu).isEnabled, "Paste was enabled with no files on the clipboard")
    }

    func testCopyPathItemsShowWhatTheyWillCopyOnASecondLine() throws {
        let menu = openMenu(on: "alpha.txt")
        // The long absolute path is elided in the middle to keep the menu narrow, so only its
        // two ends are compared; the relative path is short enough to show whole.
        let absolute = menuItem("Copy Path", in: menu).title
        XCTAssertTrue(absolute.hasPrefix("Copy Path, /"), "no absolute path under Copy Path: \(absolute)")
        XCTAssertTrue(absolute.hasSuffix("/Proj/alpha.txt"), "the path under Copy Path ends wrong: \(absolute)")
        XCTAssertEqual(menuItem("Copy Relative Path", in: menu).title, "Copy Relative Path, alpha.txt")
    }

    // MARK: - Clipboard actions

    func testCopyPathPutsTheAbsolutePathOnThePasteboard() throws {
        choose("Copy Path", on: "alpha.txt")
        eventually("the pasteboard never got the path") {
            NSPasteboard.general.string(forType: .string) == self.project.appendingPathComponent("alpha.txt").path
        }
    }

    func testCopyRelativePathPutsThePathFromTheProjectRootOnThePasteboard() throws {
        choose("Copy Relative Path", on: "alpha.txt")
        eventually("the pasteboard never got the relative path") {
            NSPasteboard.general.string(forType: .string) == "alpha.txt"
        }
    }

    func testCopyRelativePathOfAnItemInAFolderIsNested() throws {
        // Expand the folder via its disclosure triangle — a click on the name would not.
        let triangle = chevron("sub")
        XCTAssertTrue(triangle.waitForExistence(timeout: 10), "no disclosure triangle for the folder")
        triangle.click()
        XCTAssertTrue(row("inner.txt").waitForExistence(timeout: 5), "the folder didn't expand")
        choose("Copy Relative Path", on: "inner.txt")
        eventually("the pasteboard never got the nested path") {
            NSPasteboard.general.string(forType: .string) == "sub/inner.txt"
        }
    }

    func testCopyThenPasteIntoAFolderDuplicatesTheFile() throws {
        choose("Copy", on: "alpha.txt")
        choose("Paste", on: "sub")
        eventually("the copy never landed in sub/") { self.exists("sub/alpha.txt") }
        XCTAssertTrue(exists("alpha.txt"), "Copy removed the original")
    }

    func testCutThenPasteIntoAFolderMovesTheFile() throws {
        choose("Cut", on: "beta.txt")
        choose("Paste", on: "sub")
        eventually("the file never moved into sub/") { self.exists("sub/beta.txt") }
        eventually("the original is still there after a cut + paste") { !self.exists("beta.txt") }
    }

    func testPasteOnAFileLandsBesideItWithACopyName() throws {
        choose("Copy", on: "alpha.txt")
        choose("Paste", on: "beta.txt")
        eventually("no “alpha copy.txt” appeared beside the files") { self.exists("alpha copy.txt") }
    }

    // MARK: - File operations

    func testNewFileCreatesItOnDiskAndShowsItInTheTree() throws {
        choose("New File…", on: "alpha.txt")
        typeName("fresh.txt")
        eventually("fresh.txt was not created") { self.exists("fresh.txt") }
        XCTAssertTrue(row("fresh.txt").waitForExistence(timeout: 10), "the new file never showed in the tree")
    }

    func testNewFolderOnAFolderCreatesItInside() throws {
        choose("New Folder…", on: "sub")
        typeName("made")
        eventually("sub/made was not created") { self.exists("sub/made") }
    }

    func testNewFileWithATakenNameKeepsTheExistingFile() throws {
        choose("New File…", on: "alpha.txt")
        typeName("beta.txt")
        let alert = app.sheets.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "no error was shown for a name already in use")
        alert.buttons["OK"].click()
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("beta.txt"), encoding: .utf8),
                       "contents of beta.txt\n", "the existing file was overwritten")
    }

    func testRenameChangesTheNameOnDisk() throws {
        choose("Rename…", on: "alpha.txt")
        let field = app.textFields["namePrompt.name"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "alpha.txt", "the rename sheet didn't start with the current name")
        app.typeKey("a", modifierFlags: .command)
        app.typeText("renamed.txt")
        app.typeKey(.return, modifierFlags: [])
        eventually("the file was not renamed") { self.exists("renamed.txt") && !self.exists("alpha.txt") }
    }

    func testDeleteMovesTheFileToTheTrash() throws {
        choose("Delete", on: "alpha.txt")
        eventually("alpha.txt is still on disk after Delete") { !self.exists("alpha.txt") }
        XCTAssertTrue(row("alpha.txt").waitForNonExistence(timeout: 10), "the deleted file is still listed")
        XCTAssertTrue(exists("beta.txt"), "Delete took a neighbour with it")
    }

    // MARK: - Find in Folder

    func testFindInFolderScopesTheSearchToThatFolder() throws {
        choose("Find in Folder…", on: "sub")
        let scope = app.staticTexts["project-search-scope"].firstMatch
        XCTAssertTrue(scope.waitForExistence(timeout: 5), "the search sidebar doesn't show a folder scope")
        let shown = [scope.label, scope.value as? String ?? "", scope.title].joined(separator: " ")
        XCTAssertTrue(shown.contains("sub"), "the scope chip doesn't name the folder: \(scope.debugDescription)")

        let field = app.textFields["project-search-field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        app.typeText("contents")
        // Both root files say "contents"; only sub/inner.txt is in scope, and it says "inner".
        XCTAssertTrue(app.staticTexts["No matches"].waitForExistence(timeout: 10),
                      "files outside the folder were searched")
    }
}

/// Settings reach the menu: a hidden item is gone, and a group emptied by hiding leaves no
/// stray separator behind.
final class FileTreeMenuConfigUITests: FileTreeMenuUITestCase {

    override var extraLaunchArguments: [String] {
        let json = #"{"showIcons":false,"hidden":["delete","rename","findInFolder"],"shortcutOverrides":{}}"#
        // An argument value is parsed as a property list, and bare JSON isn't one — the whole
        // value is silently dropped. As a quoted plist string it arrives intact.
        let quoted = "\"" + json.replacingOccurrences(of: "\"", with: "\\\"") + "\""
        return ["-fileTree.menu", quoted]
    }

    func testHiddenItemsAreGoneAndNoSeparatorIsLeftDangling() throws {
        let menu = openMenu(on: "alpha.txt")
        XCTAssertEqual(menuLayout(menu), [
            "New File…", "New Folder…", "|",
            "Reveal in Finder", "Open in Preview", "Open in Terminal", "Open in MeatPad Terminal", "|",
            "Cut", "Copy", "Paste", "|",
            "Copy Path", "Copy Relative Path",
        ])
    }
}

/// Right-click (or control-click) on a tab: the VS Code tab menu. Middle-click-to-close can't be
/// driven by XCUITest, which has no middle button; it shares the overlay these tests exercise.
final class TabMenuUITests: FileTreeMenuUITestCase {

    func tab(_ name: String) -> XCUIElement { app.staticTexts["tab-\(name)"].firstMatch }

    /// The middle of a tab's label. Clicks go by coordinate: XCUITest reports a tab label as "not
    /// hittable" even though a real click reaches it, so what counts is what the click does.
    func tabPoint(_ name: String) -> XCUICoordinate {
        tab(name).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    }

    /// Opens `names` as tabs by clicking their rows.
    func openTabs(_ names: String...) {
        for name in names {
            row(name).click()
            XCTAssertTrue(tab(name).waitForExistence(timeout: 10), "\(name) never opened as a tab")
        }
    }

    func openTabMenu(on name: String) -> XCUIElement {
        tabPoint(name).rightClick()
        let menu = contextMenu
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "right-clicking the \(name) tab opened no menu")
        return menu
    }

    func testTabMenuHasCloseVariantsPathsAndReveal() throws {
        openTabs("alpha.txt")
        let menu = openTabMenu(on: "alpha.txt")
        XCTAssertEqual(menuLayout(menu), [
            "Close", "Close Others", "Close to the Right", "|",
            "Copy Path", "Copy Relative Path", "|",
            "Reveal in Finder",
        ])
    }

    func testCloseOthersAndCloseToTheRightAreDisabledForALoneTab() throws {
        openTabs("alpha.txt")
        let menu = openTabMenu(on: "alpha.txt")
        XCTAssertFalse(menuItem("Close Others", in: menu).isEnabled)
        XCTAssertFalse(menuItem("Close to the Right", in: menu).isEnabled)
        XCTAssertTrue(menuItem("Close", in: menu).isEnabled)
    }

    func testCloseRemovesJustThatTab() throws {
        openTabs("alpha.txt", "beta.txt")
        let menu = openTabMenu(on: "alpha.txt")
        menuItem("Close", in: menu).click()
        XCTAssertTrue(tab("alpha.txt").waitForNonExistence(timeout: 5), "the tab stayed open")
        XCTAssertTrue(tab("beta.txt").exists, "Close took the other tab with it")
    }

    func testCloseOthersKeepsOnlyThatTab() throws {
        openTabs("alpha.txt", "beta.txt")
        let menu = openTabMenu(on: "alpha.txt")
        menuItem("Close Others", in: menu).click()
        XCTAssertTrue(tab("beta.txt").waitForNonExistence(timeout: 5), "the other tab stayed open")
        XCTAssertTrue(tab("alpha.txt").exists, "Close Others closed the tab it was used on")
    }

    func testCloseToTheRightClosesOnlyTabsAfterIt() throws {
        openTabs("alpha.txt", "beta.txt")
        let menu = openTabMenu(on: "alpha.txt")
        menuItem("Close to the Right", in: menu).click()
        XCTAssertTrue(tab("beta.txt").waitForNonExistence(timeout: 5), "the tab to the right stayed open")
        XCTAssertTrue(tab("alpha.txt").exists)
    }

    func testCopyRelativePathFromATabPutsItOnThePasteboard() throws {
        openTabs("beta.txt")
        let menu = openTabMenu(on: "beta.txt")
        menuItem("Copy Relative Path", in: menu).click()
        eventually("the pasteboard never got the tab's relative path") {
            NSPasteboard.general.string(forType: .string) == "beta.txt"
        }
    }

    /// The overlay that carries the menu must not eat ordinary clicks: a plain click still
    /// switches tabs.
    func testPlainClickStillSelectsAnotherTab() throws {
        openTabs("alpha.txt", "beta.txt")
        tabPoint("alpha.txt").click()
        XCTAssertFalse(contextMenu.exists, "a plain click opened a menu")
        // The click reached the tab: it became the active one, so the tree follows it.
        eventually("a plain click on a tab didn't select it") { (self.row("alpha.txt").value as? String) == "Selected" }
        XCTAssertTrue(tab("beta.txt").exists, "a plain click closed a tab")
    }

    /// Control-click closes the tab (and, unlike the system default, doesn't open the menu —
    /// that is right-click's job).
    func testControlClickClosesTheTabWithoutOpeningAMenu() throws {
        openTabs("alpha.txt", "beta.txt")
        XCUIElement.perform(withKeyModifiers: .control) { self.tabPoint("alpha.txt").click() }
        XCTAssertTrue(tab("alpha.txt").waitForNonExistence(timeout: 5), "control-click didn't close the tab")
        XCTAssertTrue(tab("beta.txt").exists, "control-click closed the wrong tab")
        XCTAssertFalse(contextMenu.exists, "control-click opened the menu instead of just closing")
    }
}

/// The Files / Search / References bar at the top of the sidebar: every mode stays reachable and
/// none of them is jammed against a neighbour or off the edge — "References" used to run into the
/// right-hand edge of the bar.
final class SidebarModeBarUITests: FileTreeMenuUITestCase {

    private let ids = ["project-sidebar-files", "project-sidebar-search", "project-sidebar-references"]

    func testAllThreeModeButtonsAreInsideTheWindowAndDoNotOverlap() throws {
        let window = app.windows["Proj"].frame
        let frames = ids.map { app.buttons[$0].firstMatch.frame }
        for (id, frame) in zip(ids, frames) {
            XCTAssertTrue(app.buttons[id].firstMatch.exists, "\(id) is missing")
            XCTAssertTrue(window.contains(frame), "\(id) \(frame) sticks out of the window \(window)")
            XCTAssertGreaterThan(frame.width, 24, "\(id) is squeezed to nothing")
        }
        for (left, right) in zip(frames, frames.dropFirst()) {
            XCTAssertLessThanOrEqual(left.maxX, right.minX + 0.5, "neighbouring mode buttons overlap: \(left) \(right)")
        }
    }

    func testEveryModeCanBeSwitchedTo() throws {
        // The bar re-flows when the active mode changes (the others shrink to icons in a narrow
        // sidebar), so give each switch a beat before aiming at the next button.
        app.buttons["project-sidebar-references"].firstMatch.click()
        Thread.sleep(forTimeInterval: 0.8)
        app.buttons["project-sidebar-search"].firstMatch.click()
        XCTAssertTrue(app.textFields["project-search-field"].firstMatch.waitForExistence(timeout: 5), "Search didn't open")
        Thread.sleep(forTimeInterval: 0.8)
        app.buttons["project-sidebar-files"].firstMatch.click()
        XCTAssertTrue(row("alpha.txt").waitForExistence(timeout: 5), "Files didn't come back")
    }
}


/// ⌘= / ⌘− / ⌘0 on a project window: the whole window content (sidebar, tabs, editor) scales
/// together, and clicks still land where things are drawn.
final class ProjectZoomUITests: FileTreeMenuUITestCase {

    private func labelWidth(_ name: String) -> CGFloat { row(name).frame.width }

    private func zoomIn(_ times: Int) {
        for _ in 0..<times {
            app.typeKey("=", modifierFlags: .command)
            Thread.sleep(forTimeInterval: 0.4)
        }
    }

    func testZoomInScalesTheSidebarAndActualSizeRestoresIt() throws {
        let normal = labelWidth("alpha.txt")
        XCTAssertGreaterThan(normal, 10)

        zoomIn(3)   // 1.0 → 1.1 → 1.25 → 1.5
        eventually("the sidebar didn't grow at 150% (was \(normal))") { self.labelWidth("alpha.txt") > normal * 1.35 }
        XCTAssertLessThan(labelWidth("alpha.txt"), normal * 1.65, "zoomed by far more than the 150% step")

        app.typeKey("0", modifierFlags: .command)
        eventually("Actual Size didn't restore the sidebar") { abs(self.labelWidth("alpha.txt") - normal) < 2 }
    }

    /// ⌘+ as a Mac keyboard types it: ⌘⇧=.
    func testCommandShiftEqualsZoomsInToo() throws {
        let normal = app.buttons["project-sidebar-files"].firstMatch.frame.height
        app.typeKey("+", modifierFlags: [.command, .shift])
        eventually("⌘⇧= didn't zoom in (sidebar button height was \(normal))") {
            self.app.buttons["project-sidebar-files"].firstMatch.frame.height > normal * 1.05
        }
    }

    func testZoomOutShrinksTheSidebar() throws {
        let normal = labelWidth("alpha.txt")
        app.typeKey("-", modifierFlags: .command)
        app.typeKey("-", modifierFlags: .command)   // 1.0 → 0.9 → 0.8
        eventually("the sidebar didn't shrink at 80% (was \(normal))") { self.labelWidth("alpha.txt") < normal * 0.9 }
    }

    func testTheTreeStillOpensFilesAndShowsItsMenuWhenZoomed() throws {
        zoomIn(3)
        row("alpha.txt").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(app.staticTexts["tab-alpha.txt"].firstMatch.waitForExistence(timeout: 10),
                      "clicking a row at 150% didn't open the file")
        openMenu(on: "beta.txt")
        XCTAssertTrue(menuItem("Copy Path", in: contextMenu).exists, "right-clicking a row at 150% opened no menu")
    }

    /// The test that decides whether scaling the coordinate space is sound: a click at 150% must
    /// land on the line drawn under the pointer. Zoom shows each line 1.5× taller, so a click at
    /// the same spot on screen is 1/1.5 of the way down the document it was at 100% — if events
    /// were not mapped through the scale it would land on the same line again.
    func testAClickInTheEditorLandsOnTheLineUnderThePointerWhenZoomed() throws {
        let lines = (0..<60).map { String(format: "line %02d here", $0) }.joined(separator: "\n") + "\n"
        try lines.write(to: project.appendingPathComponent("lines.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(row("lines.txt").waitForExistence(timeout: 15), "the new file never showed in the tree")
        row("lines.txt").click()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "no editor opened")

        func lineHit(by marker: String) -> Int? {
            let text = editor.value as? String ?? ""
            return text.components(separatedBy: "\n").firstIndex { $0.contains(marker) }
        }
        func clickAndMark(_ marker: String) -> Int? {
            // A fixed distance from the top-left in points — NOT a fraction of the editor's height:
            // the editor's frame is the whole document, so a fraction scales with the text and
            // lands on the same line at every zoom.
            editor.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 200, dy: 240)).click()
            app.typeText(marker)
            Thread.sleep(forTimeInterval: 0.4)
            return lineHit(by: marker)
        }

        guard let atFull = clickAndMark("Q") else { return XCTFail("couldn't tell which line the 100% click landed on") }
        app.typeKey(.delete, modifierFlags: [])

        zoomIn(3)
        Thread.sleep(forTimeInterval: 0.8)
        guard let atZoom = clickAndMark("Z") else { return XCTFail("couldn't tell which line the 150% click landed on") }

        let expected = Double(atFull) / 1.5
        XCTAssertEqual(Double(atZoom), expected, accuracy: 1.6,
                       "a click at 150% landed on line \(atZoom); the 100% click hit line \(atFull), so about \(expected) was expected")
        XCTAssertLessThan(atZoom, atFull, "the 150% click landed no higher in the document than the 100% one — events aren't scaled with the drawing")
    }
}

/// Settings ▸ General ▸ Line height in code. The spacing is paragraph-style work inside the text
/// view, so it shows up as where a click lands: the same spot on screen is a lower line number
/// once the lines are spread further apart. The app is relaunched with the setting (the project
/// and its tab come back from the saved session), so both clicks hit the same file.
final class CodeLineHeightUITests: FileTreeMenuUITestCase {

    private func lineHitByClickAtAFixedPoint() -> Int? {
        let editor = app.textViews.firstMatch
        guard editor.waitForExistence(timeout: 15) else { return nil }
        // Fixed distance in points, not a fraction of the (document-sized) editor frame.
        editor.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 200, dy: 240)).click()
        app.typeText("Q")
        Thread.sleep(forTimeInterval: 0.4)
        let text = editor.value as? String ?? ""
        return text.components(separatedBy: "\n").firstIndex { $0.contains("Q") }
    }

    func testRaisingLineHeightSpreadsTheLinesOut() throws {
        let lines = (0..<80).map { String(format: "line %02d here", $0) }.joined(separator: "\n") + "\n"
        try lines.write(to: project.appendingPathComponent("lines.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(row("lines.txt").waitForExistence(timeout: 15), "the new file never showed in the tree")
        row("lines.txt").click()
        guard let atNormal = lineHitByClickAtAFixedPoint() else { return XCTFail("couldn't tell which line the click landed on") }

        // The session is saved as it changes; give it a moment, then relaunch with double line height.
        Thread.sleep(forTimeInterval: 2)
        app.terminate()
        app.launchArguments += ["-code.lineSpacing", "2"]
        app.launch()
        XCTAssertTrue(app.windows["Proj"].waitForExistence(timeout: 20), "the project didn't come back")

        guard let atDouble = lineHitByClickAtAFixedPoint() else { return XCTFail("couldn't tell which line the click landed on after the change") }
        XCTAssertLessThan(Double(atDouble), Double(atNormal) * 0.65,
                          "double line height should put the same spot on a much earlier line (normal: \(atNormal), double: \(atDouble))")
    }
}
