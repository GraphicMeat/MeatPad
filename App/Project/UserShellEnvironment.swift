import Foundation
import ProcessEnv
import MeatPadKit

/// The user's login-shell environment (their real PATH), fetched without ever waiting on the
/// main thread.
///
/// `ProcessInfo.userEnvironment` runs the user's shell and waits for it. Called on the main
/// thread — as `ProjectViewModel.init` once did, inside a SwiftUI update — that wait spins the
/// run loop, a display-link tick or screen-change notification re-enters SwiftUI mid-update, and
/// AttributeGraph aborts the app ("MeatPad quit unexpectedly" on opening a project). So the shell
/// runs once, on a background thread, and callers `await` the result.
enum UserShellEnvironment {
    private static let shellEnvironment = Task.detached(priority: .utility) {
        ProcessInfo.processInfo.userEnvironment
    }

    /// Starts the shell now so the first project window finds it already answered.
    static func warm() { _ = shellEnvironment }

    /// The shell's environment plus the language servers found on its PATH. The shell is run
    /// once per app run; detection is cheap file probing, so it re-runs for each caller and a
    /// server installed mid-session is found by the next project window.
    static func resolved() async -> LSPEnvironment {
        let environment = await shellEnvironment.value
        return await Task.detached(priority: .utility) {
            LSPEnvironment(detected: LSPServerDetector.detect(userEnvironment: environment), userEnvironment: environment)
        }.value
    }
}
