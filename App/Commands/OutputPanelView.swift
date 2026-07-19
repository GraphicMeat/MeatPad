import SwiftUI

/// Bottom pane of a project window showing a shell command's output: monospaced
/// scrollback (stderr in red), exit-code footer, close button. Fixed height so the
/// editor above keeps concrete bounds (CodeEditor placement rule).
struct OutputPanelView: View {
    let output: PanelOutput
    let onClose: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(MeatPadGlass.violet.gradient)
                Text(output.commandName).font(.caption.bold())
                if output.isRunning {
                    ProgressView().controlSize(.small)
                    Button("Cancel", action: onCancel).font(.caption)
                } else if let code = output.exitCode {
                    Text("exit \(code)")
                        .font(.caption)
                        .foregroundStyle(code == 0 ? Color.secondary : Color.red)
                }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .help("Close output panel")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if !output.stdout.isEmpty {
                        Text(output.stdout)
                            .textSelection(.enabled)
                    }
                    if !output.stderr.isEmpty {
                        Text(output.stderr)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    if output.stdout.isEmpty, output.stderr.isEmpty, !output.isRunning {
                        Text("(no output)").foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .frame(height: 180)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().opacity(0.45) }
    }
}
