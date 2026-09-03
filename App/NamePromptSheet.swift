import SwiftUI

/// One name, Cancel/commit. Replaces the `.alert` + `TextField` prompts: an NSAlert is its own
/// AppKit window, so it drew a focus ring on whichever button happened to be its first key
/// view, and the app-wide `keyboardFocusRingOnly()` policy could never reach it. A sheet is
/// SwiftUI all the way down: the field takes initial focus, rings follow the policy.
struct NamePromptSheet: View {
    let title: LocalizedStringKey
    let action: LocalizedStringKey
    @Binding var name: String
    let onCommit: () -> Void

    @Environment(\.dismiss) private var dismiss
    private enum Focus: Hashable { case name }
    @FocusState private var focus: Focus?

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Name", text: $name)
                .ringlessField()
                .focused($focus, equals: .name)
                .onSubmit(commit)
                .accessibilityIdentifier("namePrompt.name")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("namePrompt.cancel")
                Button(action) { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
                    .accessibilityIdentifier("namePrompt.commit")
            }
        }
        .padding(20)
        .frame(width: 360)
        .defaultFocus($focus, .name)
    }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        onCommit()
        dismiss()
    }
}
