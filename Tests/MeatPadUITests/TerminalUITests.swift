import AppKit
import XCTest

/// The project window's terminal panel, end to end against a real shell: ⌃` toggles it, typed
/// commands run and their output is readable through accessibility, the file-tree action
/// lands the shell in the right folder, and closing the window kills the shell.
///
/// Reuses the file-tree harness: a throwaway storage root and a throwaway `Proj` folder opened
/// as a project window.
final class TerminalUITests: FileTreeMenuUITestCase {

    private var window: XCUIElement { app.windows["Proj"] }
    private var terminal: XCUIElement { window.textViews["project-terminal"] }
    private var terminalText: String { (terminal.value as? String) ?? "" }
    /// The project editor: the window's text view that isn't the terminal. Its accessibility value
    /// is the document text. Re-resolved on every use, so after a tab change it is the new tab's editor.
    private var editor: XCUIElement {
        window.textViews.matching(NSPredicate(format: "NOT (identifier == %@)", "project-terminal")).firstMatch
    }
    private var editorText: String { (editor.value as? String) ?? "" }

    override func setUpWithError() throws {
        try super.setUpWithError()
        // A folder whose name needs quoting — "Open in MeatPad Terminal" must still land in it.
        try fm.createDirectory(at: project.appendingPathComponent("it's here", isDirectory: true), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try super.tearDownWithError()
        UserDefaults(suiteName: Self.bundleID)?.removeObject(forKey: "terminal.panelHeight")
    }

    private func toggleTerminal() {
        app.typeKey("`", modifierFlags: .control)
    }

    private func showTerminalAndWaitForShell() {
        toggleTerminal()
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "⌃` opened no terminal panel")
        waitForShell()
    }

    /// Opens `name` from the file tree and waits for its tab and editor. Retried: the first click
    /// after launch is sometimes swallowed in the full suite run (the OpenIn test's first right-click
    /// was too), which says nothing about the terminal.
    private func openInEditor(_ name: String) {
        let tab = app.staticTexts["tab-\(name)"].firstMatch
        for _ in 0..<3 where !tab.exists {
            row(name).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            _ = tab.waitForExistence(timeout: 4)
        }
        XCTAssertTrue(tab.exists, "clicking \(name) opened no tab")
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "\(name)'s tab showed no editor")
    }

    /// A child shell exists AND has drawn something (its prompt) — typing before the prompt
    /// races shell start-up.
    private func waitForShell() {
        eventually("the shell never started (no child shell of the app)", timeout: 20) { !childShells().isEmpty }
        eventually("the shell drew no prompt", timeout: 20) {
            !self.terminalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Runs `command` in the focused terminal.
    private func run(_ command: String) {
        app.typeText(command)
        app.typeKey(.return, modifierFlags: [])
    }

    private var appPID: pid_t {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
            .max { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }?.processIdentifier ?? 0
    }

    /// `"<pid> <name>"` for each direct child of the app whose command is a shell (`zsh`, `bash`,
    /// `fish`, `sh`). Reads the kernel process table with `sysctl` rather than running `pgrep`:
    /// the UI-test runner is sandboxed, and there `pgrep` and `ps` cannot reach `sysmond` and
    /// list nothing.
    private func childShells() -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        // A failed read must not look like "no shells": the reap test would pass on it.
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else {
            XCTFail("sysctl(KERN_PROC_ALL) size query failed: errno \(errno)")
            return []
        }
        // Headroom: processes can appear between the size query and the read.
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 32)
        size = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 3, &procs, &size, nil, 0) == 0 else {
            XCTFail("sysctl(KERN_PROC_ALL) read failed: errno \(errno)")
            return []
        }
        let parent = appPID
        let shells: Set<String> = ["zsh", "bash", "fish", "sh", "-zsh", "-bash", "-fish"]
        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride).compactMap { proc in
            guard proc.kp_eproc.e_ppid == parent else { return nil }
            let name = withUnsafeBytes(of: proc.kp_proc.p_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            return shells.contains(name) ? "\(proc.kp_proc.p_pid) \(name)" : nil
        }
    }

    // MARK: - Tests

    func testControlBacktickShowsTerminalThatRunsCommands() throws {
        XCTAssertFalse(terminal.exists, "the terminal panel is shown before anyone asked")
        showTerminalAndWaitForShell()

        app.typeText("printf 'mp_%s\\n' ok")
        // Positive control: the typed command is echoed, but its output isn't there yet —
        // the command line reads `mp_%s`, not `mp_ok`.
        eventually("typing didn't reach the terminal") { self.terminalText.contains("printf") }
        XCTAssertFalse(terminalText.contains("mp_ok"), "output appeared before the command ran")

        app.typeKey(.return, modifierFlags: [])
        eventually("the command's output never appeared") { self.terminalText.contains("mp_ok") }
    }

    func testToggleHidesAndRestoresPanelWithScrollback() throws {
        // An open editor with the caret in it, so hiding the terminal can be shown to hand focus
        // back there. (Before the terminal is shown, the window's only text view is the editor.)
        openInEditor("alpha.txt")
        editor.click()
        showTerminalAndWaitForShell()
        run("printf 'mp_%s\\n' kept")
        eventually("the command's output never appeared") { self.terminalText.contains("mp_kept") }
        let shellBefore = childShells()

        toggleTerminal()
        XCTAssertTrue(terminal.waitForNonExistence(timeout: 5), "⌃` with the terminal focused didn't hide it")
        // Focus went back to the editor it came from: typing lands in the document, not on the
        // bare window (which beeps and drops it). The marker isn't in "contents of alpha.txt".
        app.typeText("Zq9")
        eventually("typing after hiding the terminal didn't reach the editor") { self.editorText.contains("Zq9") }

        toggleTerminal()
        XCTAssertTrue(terminal.waitForExistence(timeout: 5), "⌃` didn't bring the terminal back")
        eventually("the scrollback was lost across hide/show") { self.terminalText.contains("mp_kept") }
        // Same pgrep line (same pid): the shell survived, it was not killed and re-spawned.
        XCTAssertEqual(childShells(), shellBefore, "hiding the panel killed or replaced the shell")
    }

    /// A tab change builds a fresh editor (`.id(url)`), so the view focus came from is gone by the
    /// time the terminal hides: focus must land on the *current* editor, not on the bare window.
    func testHideAfterTabChangeFocusesCurrentEditor() throws {
        openInEditor("alpha.txt")
        editor.click()
        showTerminalAndWaitForShell()

        openInEditor("beta.txt")
        eventually("beta.txt's editor never replaced alpha's") { self.editorText.hasPrefix("contents of beta.txt") }
        terminal.click()   // the terminal holds focus again, so ⌃` hides it
        toggleTerminal()
        XCTAssertTrue(terminal.waitForNonExistence(timeout: 5), "⌃` with the terminal focused didn't hide it")

        // The fresh editor's caret is at the start, so the marker lands in front of beta's text.
        app.typeText("Zq9")
        eventually("typing after the tab change and hide didn't reach beta's editor") {
            self.editorText.contains("contents of beta.txt") && self.editorText.contains("Zq9")
        }
    }

    func testOpenInMeatPadTerminalChangesDirectory() throws {
        choose("Open in MeatPad Terminal", on: "it's here")
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "the file-tree action opened no terminal")
        waitForShell()

        // Basename only: the full sandbox path is ~140 characters and would soft-wrap across
        // terminal rows, which the accessibility value separates with newlines.
        run("printf 'mp_%s\\n' \"${PWD##*/}\"")
        eventually("the shell isn't in the chosen folder") { self.terminalText.contains("mp_it's here") }
    }

    func testExitThenReturnRestartsShell() throws {
        showTerminalAndWaitForShell()
        run("exit 0")
        eventually("the exit line never appeared") { self.terminalText.contains("[exited 0]") }
        eventually("the shell is still alive after exit") { self.childShells().isEmpty }
        XCTAssertTrue(window.buttons["project-terminal-restart"].waitForExistence(timeout: 5), "no restart button after exit")

        app.typeKey(.return, modifierFlags: [])
        eventually("⏎ didn't restart the shell", timeout: 20) { !self.childShells().isEmpty }
        run("printf 'mp_%s\\n' again")
        eventually("the restarted shell doesn't run commands") { self.terminalText.contains("mp_again") }
    }

    func testClosingProjectWindowReapsShell() throws {
        showTerminalAndWaitForShell()
        XCTAssertFalse(childShells().isEmpty, "positive control: no shell to reap")

        window.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(window.waitForNonExistence(timeout: 10), "the project window didn't close")
        eventually("the shell outlived its window: \(childShells())") { self.childShells().isEmpty }
    }
}
