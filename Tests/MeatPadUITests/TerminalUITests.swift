import AppKit
import XCTest

/// The terminal panel's harness: the file-tree one (a throwaway storage root and a throwaway
/// `Proj` folder opened as a project window) plus ways to drive and read a real shell. No tests
/// of its own — XCTest would run every inherited test again in each subclass.
class TerminalUITestCase: FileTreeMenuUITestCase {

    var window: XCUIElement { app.windows["Proj"] }
    var terminal: XCUIElement { window.textViews["project-terminal"] }
    var terminalText: String { (terminal.value as? String) ?? "" }
    /// The project editor: the window's text view that isn't the terminal. Its accessibility value
    /// is the document text. Re-resolved on every use, so after a tab change it is the new tab's editor.
    var editor: XCUIElement {
        window.textViews.matching(NSPredicate(format: "NOT (identifier == %@)", "project-terminal")).firstMatch
    }
    var editorText: String { (editor.value as? String) ?? "" }

    override func setUpWithError() throws {
        try super.setUpWithError()
        // A folder whose name needs quoting — "Open in MeatPad Terminal" must still land in it.
        try fm.createDirectory(at: project.appendingPathComponent("it's here", isDirectory: true), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try super.tearDownWithError()
        UserDefaults(suiteName: Self.bundleID)?.removeObject(forKey: "terminal.panelHeight")
        // A Settings edit or reset is saved to the app's real defaults; don't leave one there.
        UserDefaults(suiteName: Self.bundleID)?.removeObject(forKey: "terminal.gitMenu")
    }

    func toggleTerminal() {
        app.typeKey("`", modifierFlags: .control)
    }

    func showTerminalAndWaitForShell() {
        toggleTerminal()
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "⌃` opened no terminal panel")
        waitForShell()
    }

    /// Opens `name` from the file tree and waits for its tab and editor. Retried: the first click
    /// after launch is sometimes swallowed in the full suite run (the OpenIn test's first right-click
    /// was too), which says nothing about the terminal.
    func openInEditor(_ name: String) {
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
    func waitForShell() {
        eventually("the shell never started (no child shell of the app)", timeout: 20) { !childShells().isEmpty }
        eventually("the shell drew no prompt", timeout: 20) {
            !self.terminalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Runs `command` in the focused terminal.
    func run(_ command: String) {
        app.typeText(command)
        app.typeKey(.return, modifierFlags: [])
    }

    /// Prints the shell's current folder name as `mp_<name>`. Basename only: the full sandbox
    /// path is ~140 characters and would soft-wrap across terminal rows, which the
    /// accessibility value separates with newlines.
    func printWorkingFolder() {
        run("printf 'mp_%s\\n' \"${PWD##*/}\"")
    }

    /// `eventually`, with the terminal's text in the failure message.
    func eventuallyInTerminal(_ message: String, timeout: TimeInterval = 10, _ condition: (String) -> Bool,
                                      file: StaticString = #filePath, line: UInt = #line) {
        var text = ""
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            text = terminalText
            if condition(text) { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTFail("\(message) — terminal text: \(text.debugDescription)", file: file, line: line)
    }

    /// The app under test. A vanished app fails here rather than reading as "no shells" (pid 0
    /// has no children), which would let the reap assertions pass on a crash.
    var appPID: pid_t {
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
            .max { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }?.processIdentifier
        guard let pid, pid > 0 else {
            XCTFail("the app under test isn't running")
            return 0
        }
        return pid
    }

    /// `(pid, name)` for each direct child of `parent`. Reads the kernel process table with `sysctl`
    /// rather than running `pgrep`: the UI-test runner is sandboxed, and there `pgrep` and `ps`
    /// cannot reach `sysmond` and list nothing.
    func children(of parent: pid_t) -> [(pid: pid_t, name: String)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        // A failed read must not look like "no children": the reap test would pass on it.
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
        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride).compactMap { proc in
            guard proc.kp_eproc.e_ppid == parent else { return nil }
            let name = withUnsafeBytes(of: proc.kp_proc.p_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            return (pid: proc.kp_proc.p_pid, name: name)
        }
    }

    static let shellNames: Set<String> = ["zsh", "bash", "fish", "sh", "-zsh", "-bash", "-fish"]

    /// `"<pid> <name>"` for each direct child of the app whose command is a shell (`zsh`, `bash`,
    /// `fish`, `sh`).
    func childShells() -> [String] {
        return children(of: appPID).filter { Self.shellNames.contains($0.name) }.map { "\($0.pid) \($0.name)" }
    }

    /// A `sleep` that is a direct child of one of the app's shells (a background job), and that shell.
    func backgroundSleep() -> (shell: pid_t, sleep: pid_t)? {
        for shell in children(of: appPID) where Self.shellNames.contains(shell.name) {
            if let job = children(of: shell.pid).first(where: { $0.name == "sleep" }) { return (shell.pid, job.pid) }
        }
        return nil
    }

    /// The terminal text below the last `[exited 0] — press ⏎ to restart` line: blank until the
    /// restarted shell draws its prompt.
    var textAfterLastExitLine: String {
        let text = terminalText
        guard let marker = text.range(of: "[exited 0]", options: .backwards) else { return "" }
        let rest = text[marker.upperBound...]
        guard let newline = rest.firstIndex(of: "\n") else { return "" }
        return String(rest[rest.index(after: newline)...])
    }

    func isGone(_ pid: pid_t) -> Bool {
        kill(pid, 0) == -1 && errno == ESRCH
    }

}

/// The project window's terminal panel, end to end against a real shell: ⌃` and the toolbar
/// button toggle it, typed commands run and their output is readable through accessibility, the
/// file-tree action lands the shell in the right folder, and closing the window or quitting
/// kills the shell.
final class TerminalUITests: TerminalUITestCase {

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

    /// ⇧⏎ must reach the program as ESC + CR (VS Code's soft newline), not the bare CR of ⏎.
    /// `cat -v` echoes the escape as `^[`, which plain ⏎ never produces.
    func testShiftReturnSendsEscapeCarriageReturn() throws {
        showTerminalAndWaitForShell()
        run("cat -v")
        eventually("cat never started") { self.terminalText.contains("cat -v") }

        app.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(terminalText.contains("^["), "plain ⏎ produced an escape")

        app.typeKey(.return, modifierFlags: .shift)
        eventually("⇧⏎ did not send ESC + CR") { self.terminalText.contains("^[") }
        app.typeKey("c", modifierFlags: .control)
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

    /// The toolbar button shows the terminal with focus in it, and hides it again even when the
    /// editor holds focus. A toolbar click doesn't move focus, so ⌃`'s rule (shown but not
    /// focused → focus it) would leave the panel open on the second click.
    func testToolbarButtonShowsThenHidesTerminalWithEditorFocused() throws {
        openInEditor("alpha.txt")
        editor.click()
        let toggle = window.descendants(matching: .any).matching(identifier: "project-terminal-toggle").firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "no terminal button in the project window's toolbar")

        // Re-clicked only after a click visibly did nothing: a retry must never toggle twice.
        for _ in 0..<3 where !terminal.exists {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            _ = terminal.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(terminal.exists, "the toolbar button opened no terminal panel")
        waitForShell()
        // Typed without clicking the terminal: the button handed it focus.
        run("printf 'mp_%s\\n' toolbar")
        eventuallyInTerminal("typing after the toolbar click didn't reach the shell") { $0.contains("mp_toolbar") }

        // Focus back in the editor, the case the VS Code rule gets wrong for a toolbar click.
        editor.click()
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(terminal.waitForNonExistence(timeout: 5), "the toolbar button didn't hide the terminal with the editor focused")
    }

    /// Typing right after the action must reach the shell: no shell yet → one starts in the
    /// chosen folder and takes focus; a shell at its prompt → it gets a `cd` and focus.
    func testOpenInMeatPadTerminalChangesDirectory() throws {
        XCTAssertFalse(terminal.exists, "the terminal panel is shown before anyone asked")
        choose("Open in MeatPad Terminal", on: "sub")
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "the file-tree action opened no terminal")
        waitForShell()
        printWorkingFolder()
        eventuallyInTerminal("the new shell didn't start in the chosen folder") { $0.contains("mp_sub") }

        choose("Open in MeatPad Terminal", on: "it's here")
        // The `cd` echo has the name escaped (`it'\''s here`); only the new prompt has it plain.
        eventuallyInTerminal("the running shell never showed a prompt in the chosen folder") { $0.contains("it's here") }
        printWorkingFolder()
        eventuallyInTerminal("the running shell isn't in the chosen folder") { $0.contains("mp_it's here") }
    }

    func testExitThenReturnRestartsShell() throws {
        showTerminalAndWaitForShell()
        run("exit 0")
        eventually("the exit line never appeared") { self.terminalText.contains("[exited 0]") }
        eventually("the shell is still alive after exit") { self.childShells().isEmpty }
        XCTAssertTrue(window.buttons["project-terminal-restart"].waitForExistence(timeout: 5), "no restart button after exit")

        app.typeKey(.return, modifierFlags: [])
        eventually("⏎ didn't restart the shell", timeout: 20) { !self.childShells().isEmpty }
        // Typing before the new prompt races shell start-up.
        eventually("the restarted shell drew no prompt", timeout: 20) {
            !self.textAfterLastExitLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        printWorkingFolder()
        eventuallyInTerminal("the restarted shell doesn't run commands in the project root") { $0.contains("mp_Proj") }
    }

    func testClosingProjectWindowReapsShell() throws {
        showTerminalAndWaitForShell()
        XCTAssertFalse(childShells().isEmpty, "positive control: no shell to reap")

        // A background job: it only dies with the shell if the shell is hung up (SIGHUP), not
        // SIGKILLed — a bare kill would orphan it to launchd and leave it running.
        run("sleep 1000 &")
        var sleepPID: pid_t = 0
        eventually("positive control: the background sleep never showed up as a child of the shell") {
            if let job = self.backgroundSleep() { sleepPID = job.sleep }
            return sleepPID != 0
        }

        window.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(window.waitForNonExistence(timeout: 10), "the project window didn't close")
        eventually("the shell outlived its window: \(childShells())") { self.childShells().isEmpty }
        eventually("the background job outlived the shell") { self.isGone(sleepPID) }
    }

    /// ⌘Q goes through `applicationShouldTerminate`, unlike `app.terminate()`. On app exit the
    /// kernel closes the PTY master, which hangs up the shell anyway — so this pins the
    /// user-visible property (no shell or job outlives quit), not the
    /// `terminateAllProjectTerminals()` call itself.
    func testQuitReapsShellAndJobs() throws {
        showTerminalAndWaitForShell()
        run("sleep 1000 &")
        var job: (shell: pid_t, sleep: pid_t)?
        eventually("positive control: the background sleep never showed up as a child of the shell") {
            job = self.backgroundSleep()
            return job != nil
        }
        let shellPID = try XCTUnwrap(job?.shell)
        let sleepPID = try XCTUnwrap(job?.sleep)

        app.typeKey("q", modifierFlags: .command)
        if !app.wait(for: .notRunning, timeout: 20) {
            let unsaved = app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "unsaved changes")).firstMatch
            XCTFail(unsaved.exists
                ? "⌘Q stopped at the unsaved-changes alert, but this test edits no document"
                : "the app was still running 20 s after ⌘Q")
            return
        }
        // The app is gone: from here on nothing may ask for `appPID`.
        eventually("the shell outlived quit") { self.isGone(shellPID) }
        eventually("the background job outlived quit") { self.isGone(sleepPID) }
    }
}
