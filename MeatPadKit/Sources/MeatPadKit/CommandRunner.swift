import Foundation

/// A TextMate-style command execution context: the pieces of editor state a shell
/// command may want as `TM_*` environment variables.
public struct CommandContext: Sendable {
    public var selectedText: String?
    public var filePath: String?
    public var projectDirectory: String?
    public var lineNumber: Int?
    public var columnNumber: Int?
    public var currentLine: String?
    public var currentWord: String?
    public var languageID: String?

    public init(
        selectedText: String? = nil,
        filePath: String? = nil,
        projectDirectory: String? = nil,
        lineNumber: Int? = nil,
        columnNumber: Int? = nil,
        currentLine: String? = nil,
        currentWord: String? = nil,
        languageID: String? = nil
    ) {
        self.selectedText = selectedText
        self.filePath = filePath
        self.projectDirectory = projectDirectory
        self.lineNumber = lineNumber
        self.columnNumber = columnNumber
        self.currentLine = currentLine
        self.currentWord = currentWord
        self.languageID = languageID
    }
}

/// Builds the TextMate-style `TM_*` environment variables a saved command's script
/// can read, merged over the process's own environment.
public enum TMEnvironment {
    /// Parent-environment variables passed through even when `restricted`: the
    /// minimum a shell script needs to actually function (find binaries, resolve
    /// `~`, know which shell/locale it's in, use a scratch dir) without handing an
    /// untrusted imported command the rest of the user's environment (API keys,
    /// tokens, unrelated app/session state, etc.).
    static let restrictedAllowlist = ["PATH", "HOME", "SHELL", "LANG", "TMPDIR"]

    public static func build(from ctx: CommandContext, restricted: Bool = false) -> [String: String] {
        var env: [String: String]
        if restricted {
            let parent = ProcessInfo.processInfo.environment
            env = restrictedAllowlist.reduce(into: [:]) { result, key in
                result[key] = parent[key]
            }
        } else {
            env = ProcessInfo.processInfo.environment
        }

        if let selectedText = ctx.selectedText { env["TM_SELECTED_TEXT"] = selectedText }
        if let filePath = ctx.filePath {
            env["TM_FILE_PATH"] = filePath
            env["TM_DIRECTORY"] = (filePath as NSString).deletingLastPathComponent
        }
        if let projectDirectory = ctx.projectDirectory { env["TM_PROJECT_DIRECTORY"] = projectDirectory }
        if let lineNumber = ctx.lineNumber { env["TM_LINE_NUMBER"] = String(lineNumber) }
        if let columnNumber = ctx.columnNumber { env["TM_COLUMN_NUMBER"] = String(columnNumber) }
        if let currentLine = ctx.currentLine { env["TM_CURRENT_LINE"] = currentLine }
        if let currentWord = ctx.currentWord { env["TM_CURRENT_WORD"] = currentWord }
        if let languageID = ctx.languageID { env["TM_MODE"] = languageID }

        return env
    }
}

/// The outcome of running a shell command: captured stdout/stderr, exit code, and
/// whether it was killed for exceeding its timeout.
public struct CommandResult: Equatable, Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let timedOut: Bool
}

/// Runs a script through a shell (`sh -c`-style), piping optional stdin and collecting
/// stdout/stderr concurrently so large output can't deadlock the pipe buffers. A
/// command that outruns its timeout is terminated (SIGKILL after a short grace period)
/// and reported with `timedOut: true` plus whatever output was captured so far.
public struct CommandRunner: Sendable {
    private let shell: String

    /// Ignoring SIGPIPE is required because writing stdin to a child that exits
    /// without reading it (the common case for one-liners like `echo hi`) would
    /// otherwise raise SIGPIPE and kill this ENTIRE host process, not just the
    /// runner. Pipes have no per-write "ignore" flag (unlike socket MSG_NOSIGNAL),
    /// so this is a global, process-wide disposition change — installed once,
    /// lazily, the first time a `CommandRunner` is created.
    private static let sigpipeIgnored: Bool = {
        signal(SIGPIPE, SIG_IGN)
        return true
    }()

    public init(shell: String? = nil) {
        self.shell = shell ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        _ = Self.sigpipeIgnored
    }

    public func run(
        script: String,
        stdin: String?,
        environment: [String: String],
        timeout: TimeInterval = 30
    ) async throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", script]
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdinPipe: Pipe?
        if stdin != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            stdinPipe = nil
        }

        // Drain both pipes off-thread as data arrives; reading only after `waitUntilExit`
        // would deadlock once either pipe's kernel buffer fills on large output.
        let stdoutBox = OutputBox()
        let stderrBox = OutputBox()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { stdoutBox.append(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { stderrBox.append(data) }
        }

        try process.run()

        if let stdin, let stdinPipe {
            // Off the calling task, and armed before the timeout/cancellation below:
            // a child that never reads stdin leaves this blocked on a full pipe (or
            // racing SIGPIPE once the child exits), and doing it inline here would
            // delay arming the timeout timer and cancellation handler, hanging the
            // cooperative-pool thread with no kill path.
            let handle = stdinPipe.fileHandleForWriting
            let data = Data(stdin.utf8)
            DispatchQueue.global(qos: .utility).async {
                Self.writeStdinAndClose(data, to: handle)
            }
        }

        let timedOut = TimedOutBox()

        return try await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let timeoutWorkItem = DispatchWorkItem {
                    // Only report timedOut if we actually found the process running
                    // and signaled it here — otherwise a process that exits right at
                    // the deadline (terminationHandler racing this already-started
                    // work item, whose cancel() is now a no-op) gets misreported as
                    // timed out despite finishing on its own.
                    // ponytail: residual race even with this guard — Process.isRunning
                    // (checked inside terminate()) updates asynchronously off the actual
                    // child exit, so a self-exited process right at the deadline can still
                    // be mis-flagged timedOut=true. Boolean-only impact; accepted ceiling,
                    // revisit if it ever matters.
                    if Self.terminate(process) {
                        timedOut.set(true)
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

                process.terminationHandler = { _ in
                    timeoutWorkItem.cancel()
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume()
                }
            }

            if Task.isCancelled {
                throw CancellationError()
            }

            return CommandResult(
                stdout: String(decoding: stdoutBox.data, as: UTF8.self),
                stderr: String(decoding: stderrBox.data, as: UTF8.self),
                exitCode: process.terminationStatus,
                timedOut: timedOut.value
            )
        } onCancel: {
            Self.terminate(process)
        }
    }

    /// `terminate()` (SIGTERM) then a short grace period before SIGKILL, so a script
    /// trapping SIGTERM can't hang the runner forever. Returns whether it actually
    /// found the process running and signaled it, so callers can distinguish "we
    /// killed it" from "it was already gone" (used to avoid misreporting timedOut).
    @discardableResult
    private static func terminate(_ process: Process) -> Bool {
        guard process.isRunning else { return false }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning {
                // ponytail: TOCTOU between this check and kill() — pid could in
                // theory be reused by the time the signal lands. Accepted ceiling;
                // revisit only if this ever fires against a real pid-reuse report.
                kill(process.processIdentifier, SIGKILL)
            }
        }
        return true
    }

    /// Writes `data` to `handle` in a retry loop, then always closes it — on success,
    /// on EPIPE (child exited without reading), or on any other error. SIGPIPE is
    /// ignored process-wide (see `sigpipeIgnored`), so a closed read end turns what
    /// would otherwise be a fatal signal into a plain EPIPE return from `write`.
    /// Takes the `FileHandle` itself (not a raw fd) so this closure is what keeps it
    /// alive — otherwise `FileHandle` closes its fd on dealloc, and a raw fd captured
    /// here could be double-closed or, worse, closed after the descriptor number was
    /// reused by an unrelated file.
    private static func writeStdinAndClose(_ data: Data, to handle: FileHandle) {
        let fd = handle.fileDescriptor
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var ptr = raw.baseAddress
            var remaining = raw.count
            while remaining > 0, let p = ptr {
                let n = write(fd, p, remaining)
                if n > 0 {
                    ptr = p.advanced(by: n)
                    remaining -= n
                } else if n == -1 && errno == EINTR {
                    continue
                } else {
                    break // EPIPE (child gone) or other error: stop, nothing more to write
                }
            }
        }
        try? handle.close()
    }
}

/// Thread-safe accumulator for pipe output read from a `readabilityHandler`, which
/// fires on a background queue.
private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _data = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return _data
    }

    func append(_ chunk: Data) {
        lock.lock()
        _data.append(chunk)
        lock.unlock()
    }
}

private final class TimedOutBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func set(_ newValue: Bool) {
        lock.lock()
        _value = newValue
        lock.unlock()
    }
}
