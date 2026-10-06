import AppKit
import SwiftTerm
import MeatPadKit

/// One shell per project window. Owns the terminal view for the window's lifetime so hiding
/// the panel keeps the process and its scrollback; the window's close guard and app quit call
/// `terminate()`. Start is asynchronous because the login shell's environment is fetched off
/// the main thread (`UserShellEnvironment`) — the view shows at once, the prompt follows.
@MainActor
final class ProjectTerminalController: NSObject, ObservableObject {
    let root: URL
    let view: MeatPadTerminalView

    /// OSC 0/2 title from the shell, `nil` until one arrives or when it is empty.
    @Published private(set) var title: String?
    /// OSC 7 working directory, `nil` until the shell reports one.
    @Published private(set) var currentDirectory: String?
    /// `nil` while the shell runs; the exit status (or -1 for a launch failure) afterwards.
    @Published private(set) var exitCode: Int32?

    private var startTask: Task<Void, Never>?
    /// Input handed to `send(_:)` before the shell was running; flushed right after launch.
    private var pendingInput: [String] = []
    private var lastFont: NSFont?
    /// Colours last handed to the view; `applyAppearance` only assigns the ones that changed.
    private var lastBackground: NSColor?
    private var lastForeground: NSColor?
    private var lastCaret: NSColor?
    private var lastSelection: NSColor?

    var isRunning: Bool { view.process?.running ?? false }

    init(root: URL) {
        self.root = root
        // SwiftTerm 1.11.0 has no options initializer; scrollback is its default (500 lines).
        view = MeatPadTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        super.init()
        view.processDelegate = self
        // Off, like Terminal.app: on, Option+key sends ESC+char and breaks layouts that type with
        // Option (Lithuanian digits, DE/FR `@[]{}|~`).
        view.optionAsMetaKey = false
        view.onRestartRequested = { [weak self] in self?.restart() }
    }

    /// Launches the shell unless it is already running or launching.
    func startIfNeeded() {
        guard startTask == nil, !isRunning else { return }
        startTask = Task { [weak self] in
            let environment = await UserShellEnvironment.resolved().userEnvironment
            guard !Task.isCancelled, let self else { return }
            self.start(userEnvironment: environment)
        }
    }

    /// Launches a fresh shell in the project root after the previous one exited. Only reachable
    /// once `exitCode` is set (⏎ in the dead terminal, the header's Restart button), so there is
    /// never a live shell to kill here.
    func restart() {
        guard !isRunning else { return }
        startIfNeeded()
    }

    /// Kills the shell and reaps it, and cancels a start still waiting for the login-shell
    /// environment. SwiftTerm 1.11.0's `terminate()` only sends SIGTERM, which interactive shells
    /// ignore, and leaves the PTY master open, so the shell is also sent SIGHUP (what closing a
    /// terminal sends: zsh/bash exit and hang up their jobs). SwiftTerm never calls `waitpid`
    /// itself; its exit monitor stays armed and reaps with WNOHANG once the child dies, which can
    /// race the loop below (`ECHILD` = the monitor won) and can deliver a late `processTerminated`
    /// after this call; that only feeds an exit line into a view whose window is closing, which
    /// is harmless. The loop escalates to SIGKILL after 5 s, always after a fresh failed check.
    func terminate() {
        guard isRunning else { startTask?.cancel(); startTask = nil; return }
        let pid = view.process.shellPid
        view.terminate()
        guard pid > 0 else { return }
        kill(pid, SIGHUP)
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            func reaped() -> Bool {
                let result = waitpid(pid, &status, WNOHANG)
                return result == pid || (result == -1 && errno == ECHILD)
            }
            for _ in 0..<50 {
                if reaped() { return }
                usleep(100_000)
            }
            if reaped() { return }
            kill(pid, SIGKILL)
            waitpid(pid, &status, 0)
        }
    }

    /// Types `text` into the shell; queued until the shell is running.
    func send(_ text: String) {
        if isRunning { view.send(txt: text) } else { pendingInput.append(text) }
    }

    /// Colours from the active theme, the editor's monospaced font at `fontSize` (already
    /// multiplied by the project zoom by the caller). Cheap to call on every SwiftUI update:
    /// each value is only assigned when it differs from the last one applied, because every
    /// SwiftTerm colour assignment flushes its caches and queues a full redraw (the background
    /// and foreground ones also rebuild the ANSI palette, discarding OSC 4 colours a running
    /// program set), and a font assignment re-lays out the grid.
    func applyAppearance(theme: Theme, fontSize: CGFloat) {
        let background = NSColor(theme.editorBackground)
        if background != lastBackground {
            view.nativeBackgroundColor = background
            lastBackground = background
        }
        let foreground = NSColor(theme.editorForeground)
        if foreground != lastForeground {
            view.nativeForegroundColor = foreground
            lastForeground = foreground
        }
        let caret = NSColor(theme.caret)
        if caret != lastCaret {
            view.caretColor = caret
            lastCaret = caret
        }
        let selection = NSColor(theme.selection)
        if selection != lastSelection {
            view.selectedTextBackgroundColor = selection
            lastSelection = selection
        }
        if lastFont?.pointSize != fontSize {
            let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            view.font = font
            lastFont = font
        }
    }

    private func start(userEnvironment: [String: String]) {
        let spec = TerminalLaunch.spec(root: root, userEnvironment: userEnvironment)
        exitCode = nil
        view.exitCode = nil
        // SwiftTerm 1.11.0 never reports an exec failure (the forked child has no `_exit` after a
        // failed `execve`, so it would carry on as a copy of MeatPad), so check up front.
        guard FileManager.default.isExecutableFile(atPath: spec.executable) else {
            failStart(spec.executable)
            return
        }
        view.startProcess(
            executable: spec.executable,
            args: spec.args,
            environment: spec.environment,
            currentDirectory: spec.currentDirectory
        )
        // Second line of defence: a forkpty failure makes `startProcess` return silently, with no
        // delegate call.
        guard isRunning else {
            failStart(spec.executable)
            return
        }
        for text in pendingInput { view.send(txt: text) }
        pendingInput.removeAll()
    }

    private func failStart(_ executable: String) {
        view.feed(text: "\r\n" + String(localized: "Could not start \(executable)") + "\r\n")
        markExited(-1)
    }

    private func markExited(_ code: Int32) {
        exitCode = code
        view.exitCode = code
        startTask = nil
    }
}

extension ProjectTerminalController: LocalProcessTerminalViewDelegate {
    // SwiftTerm may call these off the main thread; every one hops to the actor.

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor in self.title = title.isEmpty ? nil : title }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // OSC 7 carries a file: URL; keep the path.
        let path = directory.flatMap { URL(string: $0)?.path ?? $0 }
        Task { @MainActor in self.currentDirectory = path }
    }

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        // SwiftTerm 1.11.0 passes the raw `waitpid` status here (`exit 3` arrives as 768), hence the decode.
        let code = TerminalExitStatus.exitCode(fromWaitStatus: exitCode)
        Task { @MainActor in
            self.view.feed(text: "\r\n" + String(localized: "[exited \(code)] — press ⏎ to restart") + "\r\n")
            self.markExited(code)
        }
    }
}
