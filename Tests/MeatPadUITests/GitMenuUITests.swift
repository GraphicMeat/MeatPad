import XCTest

/// Driving the terminal header's Git menu: open it, pick an item.
class GitMenuUITestCase: TerminalUITestCase {

    var gitMenu: XCUIElement {
        window.descendants(matching: .any).matching(identifier: "terminal-git-menu").firstMatch
    }

    /// An item of the open Git menu, by its exact title (`git stash` must not match `git stash pop`).
    func gitMenuItem(_ title: String) -> XCUIElement {
        app.menuItems.matching(NSPredicate(format: "title == %@", title)).firstMatch
    }

    /// Opens the menu and clicks `title`. The menu is reopened (twice at most) when a click on it
    /// was swallowed or the menu closed again before the item could be found.
    func chooseFromGitMenu(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(gitMenu.waitForExistence(timeout: 10), "no Git menu in the terminal header", file: file, line: line)
        let item = gitMenuItem(title)
        for _ in 0..<3 where !item.exists {
            gitMenu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            _ = item.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(item.exists, "no “\(title)” in the Git menu", file: file, line: line)
        item.click()
    }

    /// The shell runs `git init` itself: the sandboxed test runner can't easily make a repository.
    /// Waits for it to finish — while git owns the terminal, a menu click only beeps.
    func showTerminalInARepository() {
        showTerminalAndWaitForShell()
        run("git init -q && printf 'mp_%s\\n' ready")
        eventuallyInTerminal("git init never finished", timeout: 20) { $0.contains("mp_ready") }
    }
}

/// The default menu against a real repository: a run item runs, a type item is only typed, with
/// the caret where the user goes on typing.
final class GitMenuUITests: GitMenuUITestCase {

    func testGitStatusRunsInTheShell() throws {
        showTerminalInARepository()
        chooseFromGitMenu("git status")
        eventuallyInTerminal("git status never ran") { $0.contains("On branch") || $0.contains("No commits yet") }
    }

    /// Focus starts in the editor, so the typed message only reaches the shell if the click
    /// handed the terminal focus. Typed, not run: a commit in a repository with nothing staged
    /// would say "nothing added to commit".
    func testCommitIsTypedWithTheCaretBetweenTheQuotes() throws {
        showTerminalInARepository()
        openInEditor("alpha.txt")
        editor.click()

        chooseFromGitMenu(#"git commit -m """#)
        app.typeText("msg")
        eventuallyInTerminal("the message didn't land between the quotes") { $0.contains(#"git commit -m "msg""#) }
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(terminalText.contains("nothing to commit"), "the commit ran instead of being typed")
        XCTAssertFalse(terminalText.contains("nothing added to commit"), "the commit ran instead of being typed")
        XCTAssertFalse(editorText.contains("msg"), "the message went to the editor, not the terminal")
    }
}

/// A configured menu replaces the built-in one, and Settings ▸ Terminal can put the defaults back.
final class GitMenuConfigUITests: GitMenuUITestCase {

    override var extraLaunchArguments: [String] {
        let json = #"{"items":[{"command":"echo mp_custom","run":true}]}"#
        // An argument value is parsed as a property list, and bare JSON isn't one — the whole
        // value is silently dropped. As a quoted plist string it arrives intact.
        let quoted = "\"" + json.replacingOccurrences(of: "\"", with: "\\\"") + "\""
        return ["-terminal.gitMenu", quoted]
    }

    /// The echoed command line also says `mp_custom`, so only a line that is nothing else proves
    /// the command ran.
    func testAConfiguredCommandRuns() throws {
        showTerminalAndWaitForShell()
        let custom = gitMenuItem("echo mp_custom")
        XCTAssertTrue(gitMenu.waitForExistence(timeout: 10), "no Git menu in the terminal header")
        for _ in 0..<3 where !custom.exists {
            gitMenu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            _ = custom.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(custom.exists, "the configured command isn't in the Git menu")
        XCTAssertFalse(gitMenuItem("git status").exists, "the built-in items are still in a configured menu")
        custom.click()
        eventuallyInTerminal("the configured command never ran") { text in
            text.components(separatedBy: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "mp_custom" }
        }
    }

    func testResetToDefaultsInSettingsRestoresTheBuiltInMenu() throws {
        showTerminalAndWaitForShell()
        app.typeKey(",", modifierFlags: .command)
        let tab = app.descendants(matching: .any).matching(identifier: "settings-terminal-tab").firstMatch
        let byName = app.toolbars.buttons["Terminal"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10) || byName.waitForExistence(timeout: 2), "Settings has no Terminal tab")
        (tab.exists ? tab : byName).click()

        let reset = app.descendants(matching: .any).matching(identifier: "settings.terminal.gitMenu.reset").firstMatch
        XCTAssertTrue(reset.waitForExistence(timeout: 5), "the Terminal tab has no Reset to Defaults")
        reset.click()
        app.typeKey("w", modifierFlags: .command)

        chooseFromGitMenu("git status")
        eventuallyInTerminal("the restored git status didn't run") {
            $0.contains("On branch") || $0.contains("not a git repository")
        }
    }
}
