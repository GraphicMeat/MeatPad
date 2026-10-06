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
    ///   - root: the project folder; the shell starts there.
    ///   - userEnvironment: the login shell's environment (its `SHELL` and `PATH` win).
    ///   - processEnvironment: the app's own environment, consulted only for `SHELL` when the
    ///     user environment has none.
    public static func spec(
        root: URL,
        userEnvironment: [String: String],
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TerminalLaunchSpec {
        var merged = userEnvironment
        merged["TERM"] = "xterm-256color"
        merged["COLORTERM"] = "truecolor"
        merged["TERM_PROGRAM"] = "MeatPad"
        if merged["LANG"]?.isEmpty ?? true { merged["LANG"] = "en_US.UTF-8" }
        let environment = merged.keys.sorted().map { "\($0)=\(merged[$0]!)" }
        return TerminalLaunchSpec(
            executable: shell(userEnvironment: userEnvironment, processEnvironment: processEnvironment),
            args: ["-l"],
            environment: environment,
            currentDirectory: root.path
        )
    }

    /// `cd` into `url`, single-quoted for POSIX shells (`'` becomes `'\''`), newline-terminated
    /// so the shell runs it as soon as it reads its input.
    public static func changeDirectoryCommand(to url: URL) -> String {
        let escaped = url.path.replacingOccurrences(of: "'", with: "'\\''")
        return "cd '\(escaped)'\n"
    }

    private static func shell(userEnvironment: [String: String], processEnvironment: [String: String]) -> String {
        for candidate in [userEnvironment["SHELL"], processEnvironment["SHELL"]] {
            if let candidate, candidate.hasPrefix("/") { return candidate }
        }
        return fallbackShell
    }
}
