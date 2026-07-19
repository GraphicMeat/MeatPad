import SwiftUI
import MeatPadKit

/// Confirmation gate for a command whose `trusted` flag is false — shown by
/// `CommandExecutor.run` in place of executing anything. Presentation follows
/// `FilterCommandSheet`'s pattern: the executor publishes `trustRequest` keyed by the
/// requesting window's `hostID`, and each window type's `.sheet(item:)` picks it up
/// when the id matches (see `ProjectWindow`/`NoteWindow`/`NotesBrowserWindow`).
struct CommandTrustSheet: View {
    let request: CommandTrustRequest
    let onCancel: () -> Void
    let onRunOnce: () -> Void
    let onTrustAndRun: () -> Void

    private var command: SavedCommand { request.command }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Untrusted Command", systemImage: "exclamationmark.shield.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(command.name).font(.title3.bold())
                if case .imported(let bundleName, _) = command.origin {
                    Text("Imported from \u{201C}\(bundleName)\u{201D} \u{2014} hasn\u{2019}t been run before.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Text("This will run the following shell script:").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(command.script)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(6)
            }
            .frame(minHeight: 100, maxHeight: 220)
            .border(.quaternary)

            VStack(alignment: .leading, spacing: 4) {
                detailRow("Working directory", workingDirectoryText)
                detailRow("Input", inputText)
                detailRow("Environment", environmentText)
                detailRow("Timeout", "\(Int(command.timeoutSeconds ?? 30))s")
            }
            .font(.caption)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Run Once", action: onRunOnce)
                Button("Trust and Run", action: onTrustAndRun)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value)
        }
    }

    /// Truthful, not aspirational: `CommandRunner` launches the process without setting
    /// `currentDirectoryURL`, so the shell's actual working directory is the app's own
    /// process cwd — NOT the open file's folder or the project root. Those are only
    /// visible to the script as `TM_DIRECTORY`/`TM_PROJECT_DIRECTORY` env vars (when a
    /// file/project is open), surfaced below as context, not as the real cwd.
    private var workingDirectoryText: String {
        var text = FileManager.default.currentDirectoryPath
        if let fileURL = request.context.fileURL {
            text += "\n(script also sees TM_DIRECTORY=\(fileURL.deletingLastPathComponent().path))"
        }
        if let projectRoot = request.context.projectRoot {
            text += "\n(TM_PROJECT_DIRECTORY=\(projectRoot.path))"
        }
        return text
    }

    private var inputText: String {
        switch command.input {
        case .none: return "None"
        case .selection: return "Selection (falls back to whole document if nothing is selected)"
        case .document: return "Whole document"
        }
    }

    private var environmentText: String {
        command.restrictedEnvironment
            ? "Restricted \u{2014} only TM_* variables plus PATH/HOME/SHELL/LANG/TMPDIR"
            : "Full \u{2014} inherits the app\u{2019}s entire process environment"
    }
}
