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
        eventually("the shell never started (no child shell of the app)", timeout: 20) { !childShells().isEmpty }
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

    /// `pgrep -lP <app pid>` lines whose command is a shell (`zsh`, `bash`, `fish`, `sh`).
    private func childShells() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-lP", String(appPID)]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return output.split(separator: "\n").map(String.init).filter { line in
            let name = line.split(separator: " ").last.map(String.init) ?? ""
            return ["zsh", "bash", "fish", "sh", "-zsh", "-bash", "-fish"].contains(name)
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
        showTerminalAndWaitForShell()
        run("printf 'mp_%s\\n' kept")
        eventually("the command's output never appeared") { self.terminalText.contains("mp_kept") }

        toggleTerminal()
        XCTAssertTrue(terminal.waitForNonExistence(timeout: 5), "⌃` with the terminal focused didn't hide it")
        // Focus went back to the window: typing lands somewhere harmless, not in a dead responder.
        app.typeText("x")
        XCTAssertFalse(childShells().isEmpty, "hiding the panel killed the shell")

        toggleTerminal()
        XCTAssertTrue(terminal.waitForExistence(timeout: 5), "⌃` didn't bring the terminal back")
        eventually("the scrollback was lost across hide/show") { self.terminalText.contains("mp_kept") }
    }

    func testOpenInMeatPadTerminalChangesDirectory() throws {
        choose("Open in MeatPad Terminal", on: "it's here")
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "the file-tree action opened no terminal")
        eventually("the shell never started", timeout: 20) { !childShells().isEmpty }

        run("printf 'mp_%s\\n' \"$PWD\"")
        eventually("the shell isn't in the chosen folder") { self.terminalText.contains("mp_" + self.project.appendingPathComponent("it's here").path) }
    }

    func testExitThenReturnRestartsShell() throws {
        showTerminalAndWaitForShell()
        run("exit")
        eventually("the exit line never appeared") { self.terminalText.contains("[exited 0]") }
        eventually("the shell is still alive after exit") { self.childShells().isEmpty }
        XCTAssertTrue(window.buttons["project-terminal-restart"].exists, "no restart button after exit")

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
