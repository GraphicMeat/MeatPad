import Foundation

/// Everything needed to fork the user's interactive shell on a PTY inside a project window.
/// Built by `TerminalLaunch.spec` from the login shell's environment (`UserShellEnvironment`
/// in the app), so a GUI-launched MeatPad still gets the real PATH, and handed verbatim to
/// SwiftTerm's `startProcess`.
public struct TerminalLaunchSpec: Equatable, Sendable {
    public let executable: String
    public let args: [String]
    /// `KEY=VALUE` entries, sorted by key, no duplicates.
    public let environment: [String]
    public let currentDirectory: String
}

public enum TerminalLaunch {
    static let fallbackShell = "/bin/zsh"

    /// - Parameters:
    ///   - root: the folder the shell starts in — the project folder, or the one File tree ▸
    ///     Open in MeatPad Terminal chose.
    ///   - userEnvironment: the login shell's environment (its `SHELL` and `PATH` win).
    ///   - processEnvironment: the app's own environment, consulted only for `SHELL` when the
    ///     user environment has no usable one.
    ///   - isExecutable: whether a candidate shell path can be launched. A `SHELL` naming a
    ///     shell that was uninstalled (or a relative path) falls through to the next candidate:
    ///     the user's `SHELL`, then the app's, then `/bin/zsh`.
    public static func spec(
        root: URL,
        userEnvironment: [String: String],
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> TerminalLaunchSpec {
        let executable = shell(
            userEnvironment: userEnvironment, processEnvironment: processEnvironment, isExecutable: isExecutable
        )
        var merged = userEnvironment
        // Programs in the terminal see the shell that actually runs, not one that fell through.
        merged["SHELL"] = executable
        merged["TERM"] = "xterm-256color"
        merged["COLORTERM"] = "truecolor"
        merged["TERM_PROGRAM"] = "MeatPad"
        if merged["LANG"]?.isEmpty ?? true { merged["LANG"] = "en_US.UTF-8" }
        let environment = merged.keys.sorted().map { "\($0)=\(merged[$0]!)" }
        return TerminalLaunchSpec(
            executable: executable,
            args: ["-l"],
            environment: environment,
            currentDirectory: root.path
        )
    }

    /// `cd` into `url`, single-quoted for POSIX shells (`'` becomes `'\''`), newline-terminated
    /// so the shell runs it as soon as it reads its input. It starts with ⌃U, which clears
    /// anything half-typed at the prompt first (zsh kills the whole line, bash back to its start),
    /// so the `cd` never runs glued to the user's unfinished command.
    public static func changeDirectoryCommand(to url: URL) -> String {
        let escaped = url.path.replacingOccurrences(of: "'", with: "'\\''")
        return "\u{15}cd '\(escaped)'\n"
    }

    private static func shell(
        userEnvironment: [String: String],
        processEnvironment: [String: String],
        isExecutable: (String) -> Bool
    ) -> String {
        for candidate in [userEnvironment["SHELL"], processEnvironment["SHELL"]] {
            if let candidate, candidate.hasPrefix("/"), isExecutable(candidate) { return candidate }
        }
        return fallbackShell
    }
}
