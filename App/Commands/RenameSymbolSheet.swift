import SwiftUI

/// Rename Symbol prompt (0.7 LSP plan Task 6): same one-field-plus-Cancel/Run shape as
/// `FilterCommandSheet`, minus that sheet's saved-command chrome. Unlike the Filter sheet
/// (routed through the app-wide `CommandExecutor.filterContext` because Commands are
/// shared across every window type), this is bound directly to the owning project's own
/// `ProjectViewModel.renameRequest` — rename only ever happens in a project window with a
/// live LSP server, so there's no cross-window host to match.
struct RenameSymbolSheet: View {
    let request: RenameSymbolRequest
    @ObservedObject var project: ProjectViewModel

    @State private var name: String

    init(request: RenameSymbolRequest, project: ProjectViewModel) {
        self.request = request
        self.project = project
        _name = State(initialValue: request.defaultName)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Symbol").font(.headline)
            Text("Renaming “\(request.defaultName)” in \(request.fileURL.lastPathComponent) and everywhere else it's used.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("New name", text: $name)
                .font(.system(.body, design: .monospaced))
                .onSubmit(run)

            HStack {
                Spacer()
                Button("Cancel") { project.renameRequest = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || trimmedName == request.defaultName)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func run() {
        guard !trimmedName.isEmpty, trimmedName != request.defaultName else { return }
        project.performRename(request, newName: trimmedName)
        project.renameRequest = nil
    }
}
