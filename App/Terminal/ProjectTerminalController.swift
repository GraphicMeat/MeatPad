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

    var isRunning: Bool { view.process?.running ?? false }

    init(root: URL) {
        self.root = root
        // SwiftTerm 1.11.0 has no options initializer; scrollback is its default (500 lines).
        view = MeatPadTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        super.init()
        view.processDelegate = self
        view.optionAsMetaKey = true
        view.onRestartRequested = { [weak self] in self?.restart() }
    }

    /// Launches the shell unless it is already running or launching.
    func startIfNeeded() {
        guard startTask == nil, !isRunning else { return }
        startTask = Task { [weak self] in
            let environment = await UserShellEnvironment.resolved().userEnvironment
            guard let self else { return }
            self.start(userEnvironment: environment)
        }
    }

    /// Launches a fresh shell in the project root after the previous one exited. Only reachable
    /// once `exitCode` is set (⏎ in the dead terminal, the header's Restart button), so there is
    /// never a live shell to kill here.
    func restart() {
        guard !isRunning else { return }
        startTask = nil
        startIfNeeded()
    }

    /// Kills the shell and reaps it. SwiftTerm 1.11.0's `terminate()` closes the PTY master and
    /// sends SIGTERM but never calls `waitpid` itself; its exit monitor stays armed and reaps
    /// with WNOHANG once the child dies, which can race the loop below (`ECHILD` = the monitor
    /// won). The loop finishes the job and escalates to SIGKILL after 5 s for a process that
    /// ignores SIGTERM.
    /// 1.11.0 also leaves its exit monitor armed, so a late `processTerminated` callback can
    /// follow this call; it only feeds an exit line into a view whose window is closing, which
    /// is harmless.
    func terminate() {
        guard isRunning else { return }
        let pid = view.process.shellPid
        view.terminate()
        guard pid > 0 else { return }
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            for _ in 0..<50 {
                let reaped = waitpid(pid, &status, WNOHANG)
                if reaped == pid || (reaped == -1 && errno == ECHILD) { return }
                usleep(100_000)
            }
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
    /// the font is only reassigned when its size changes (SwiftTerm re-lays out on assignment).
    func applyAppearance(theme: Theme, fontSize: CGFloat) {
        view.nativeBackgroundColor = NSColor(theme.editorBackground)
        view.nativeForegroundColor = NSColor(theme.editorForeground)
        view.caretColor = NSColor(theme.caret)
        view.selectedTextBackgroundColor = NSColor(theme.selection)
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
        view.startProcess(
            executable: spec.executable,
            args: spec.args,
            environment: spec.environment,
            currentDirectory: spec.currentDirectory
        )
        // SwiftTerm 1.11.0's startProcess returns silently when forkpty/exec fails — no delegate call.
        guard isRunning else {
            view.feed(text: "\r\n" + String(localized: "Could not start \(spec.executable)") + "\r\n")
            markExited(-1)
            return
        }
        for text in pendingInput { view.send(txt: text) }
        pendingInput.removeAll()
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
