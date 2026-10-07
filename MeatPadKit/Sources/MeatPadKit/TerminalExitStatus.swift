import Foundation

/// Decodes a raw `waitpid` status word the way `WEXITSTATUS`/`WTERMSIG` do — SwiftTerm 1.11.0
/// passes the status, not the exit code, to its termination delegate.
public enum TerminalExitStatus {
    /// Normal exit → 0…255; killed by signal N → `-N`; `nil` (wait failed) → `-1`.
    public static func exitCode(fromWaitStatus status: Int32?) -> Int32 {
        guard let status else { return -1 }
        let signal = status & 0x7f
        if signal == 0 { return (status >> 8) & 0xff }
        return -signal
    }
}
