import AppKit
import XCTest

/// The project folder as the tree's top row, as in VS Code's Explorer: it folds the whole tree
/// like any folder, and its right-click menu is the folder menu minus what makes no sense on the
/// project itself (cut, copy, rename, delete, a relative path that would be empty).
final class FileTreeRootUITests: FileTreeMenuUITestCase {

    /// The root row's name. By identifier, never by label: the window is titled "Proj" too.
    var rootRow: XCUIElement {
        app.windows["Proj"].descendants(matching: .any)["file-tree-root"].firstMatch
    }

    private func requireRoot(file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let root = rootRow
        XCTAssertTrue(root.waitForExistence(timeout: 10), "the file tree has no root row for the project",
                      file: file, line: line)
        return root
    }

    private func chooseOnRoot(_ item: String) {
        let menu = openMenu(onElement: requireRoot(), named: "the root")
        let entry = menuItem(item, in: menu)
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "no “\(item)” in the root's menu")
        entry.click()
    }

    /// The root's folder icon, past its chevron — see `folderIcon(atY:)`.
    private func rootIcon() -> XCUICoordinate { folderIcon(atY: requireRoot().frame.midY) }

    func testTreeShowsTheProjectFolderAsItsRoot() throws {
        let root = requireRoot()
        XCTAssertEqual(root.label, "Proj", "the root row isn't named after the project folder")
        let alpha = row("alpha.txt")
        XCTAssertTrue(alpha.waitForExistence(timeout: 5), "the root's files aren't shown")
        XCTAssertGreaterThan(alpha.frame.minY, root.frame.minY, "alpha.txt isn't below the root row")
        XCTAssertGreaterThan(alpha.frame.minX, root.frame.minX, "alpha.txt isn't indented under the root row")
    }

    func testRootMenuOmitsCutCopyRenameDeleteAndRelativePathButHasFindInProject() throws {
        let menu = openMenu(onElement: requireRoot(), named: "the root")
        for present in ["Find in Project…", "New File…", "Paste", "Copy Path", "Reveal in Finder"] {
            XCTAssertTrue(menuItem(present, in: menu).exists, "the root's menu has no “\(present)”: \(menuLayout(menu))")
        }
        // "Copy" matches only an item titled exactly that (or "Copy, …"), never "Copy Path".
        for absent in ["Cut", "Copy", "Rename…", "Delete", "Copy Relative Path", "Find in Folder…"] {
            XCTAssertFalse(menuItem(absent, in: menu).exists, "the root's menu offers “\(absent)”: \(menuLayout(menu))")
        }
    }

    func testFindInProjectFromTheRootHasNoFolderScope() throws {
        chooseOnRoot("Find in Project…")
        let field = app.textFields["project-search-field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Find in Project didn't open the search sidebar")
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(app.staticTexts["project-search-scope"].firstMatch.exists,
                       "Find in Project from the root limited the search to a folder")
    }

    /// ⌘⇧F is "Find in Project": a folder scope left over from Find in Folder must not stick.
    func testFindInProjectShortcutClearsAFolderScope() throws {
        choose("Find in Folder…", on: "sub")
        let scope = app.staticTexts["project-search-scope"].firstMatch
        XCTAssertTrue(scope.waitForExistence(timeout: 5), "Find in Folder showed no folder scope")

        app.typeKey("f", modifierFlags: [.command, .shift])
        XCTAssertTrue(scope.waitForNonExistence(timeout: 5), "⌘⇧F kept searching only the folder")
        let field = app.textFields["project-search-field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        eventually("the search field doesn't have keyboard focus after ⌘⇧F") {
            (field.value(forKey: "hasKeyboardFocus") as? Bool) == true
        }
    }

    func testCollapsingTheRootHidesEveryRowAndExpandingShowsThemAgain() throws {
        XCTAssertTrue(row("alpha.txt").exists, "the root starts folded")
        rootIcon().click()
        XCTAssertTrue(row("alpha.txt").waitForNonExistence(timeout: 5), "clicking the root's icon didn't fold the project")
        XCTAssertFalse(row("beta.txt").exists, "folding the root left beta.txt showing")
        XCTAssertFalse(row("sub").exists, "folding the root left the sub folder showing")
        XCTAssertTrue(rootRow.exists, "folding the root hid the root row itself")

        rootIcon().click()
        XCTAssertTrue(row("alpha.txt").waitForExistence(timeout: 5), "clicking the root's icon again didn't unfold it")
        XCTAssertTrue(row("sub").exists, "unfolding the root didn't bring the sub folder back")
    }

    func testNewFileOnTheRootCreatesItAtTheProjectRoot() throws {
        chooseOnRoot("New File…")
        typeName("fresh.txt")
        eventually("fresh.txt was not created at the project root") { self.exists("fresh.txt") }
        XCTAssertFalse(fm.fileExists(atPath: sandbox.appendingPathComponent("fresh.txt").path),
                       "the new file went into the project's parent folder")
        XCTAssertTrue(row("fresh.txt").waitForExistence(timeout: 10), "the new file never showed in the tree")
    }
}
