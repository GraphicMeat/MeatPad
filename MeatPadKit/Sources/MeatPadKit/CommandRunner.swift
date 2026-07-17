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
    public static func build(from ctx: CommandContext) -> [String: String] {
        var env = ProcessInfo.processInfo.environment

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

    public init(shell: String? = nil) {
        self.shell = shell ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
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
            stdinPipe.fileHandleForWriting.write(Data(stdin.utf8))
        }
        try? stdinPipe?.fileHandleForWriting.close()

        let timedOut = TimedOutBox()

        return try await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let timeoutWorkItem = DispatchWorkItem {
                    timedOut.set(true)
                    Self.terminate(process)
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
    /// trapping SIGTERM can't hang the runner forever.
    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
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
