import SwiftUI
import MeatPadKit

/// One-off "Filter Through Command…" (Cmd+Opt+R): a shell one-liner over the focused
/// editor, with the same input/output modes as saved commands. Remembers the last entry.
struct FilterCommandSheet: View {
    let context: EditorCommandContext
    let onDismiss: () -> Void

    @AppStorage("filterCommand.script") private var script = ""
    @AppStorage("filterCommand.input") private var inputRaw = CommandInput.selection.rawValue
    @AppStorage("filterCommand.output") private var outputRaw = CommandOutputMode.replaceSelection.rawValue
    @ObservedObject private var executor = AppModel.shared.commandExecutor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Filter Through Command").font(.headline)
            TextField("Shell command (e.g. sort -u)", text: $script)
                .font(.system(.body, design: .monospaced))
                .onSubmit(run)

            Picker("Input", selection: $inputRaw) {
                Text("None").tag(CommandInput.none.rawValue)
                Text("Selection").tag(CommandInput.selection.rawValue)
                Text("Document").tag(CommandInput.document.rawValue)
            }
            Picker("Output", selection: $outputRaw) {
                Text("Replace Selection").tag(CommandOutputMode.replaceSelection.rawValue)
                Text("Insert at Caret").tag(CommandOutputMode.insertAtCaret.rawValue)
                Text("New Note").tag(CommandOutputMode.newNote.rawValue)
                Text("Output Panel").tag(CommandOutputMode.outputPanel.rawValue)
            }
            if !context.panelCapable {
                Text("Output Panel opens a new note in note windows.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onDismiss).keyboardShortcut(.cancelAction)
                Button("Run", action: run)
                    .keyboardShortcut(.defaultAction)
                    .disabled(script.trimmingCharacters(in: .whitespaces).isEmpty || executor.isRunning)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func run() {
        let command = SavedCommand(
            name: script,
            script: script,
            input: CommandInput(rawValue: inputRaw) ?? .selection,
            output: CommandOutputMode(rawValue: outputRaw) ?? .replaceSelection
        )
        executor.run(command, context: context)
        onDismiss()
    }
}
