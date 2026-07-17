import SwiftUI
import MeatPadKit

/// Settings ▸ Snippets: the full snippet catalog. Built-in rows are badged and read-only;
/// user rows can be edited or deleted. "Duplicate" turns any row (including a builtin) into
/// an editable user copy — a copy that keeps a builtin's trigger + language scope shadows it.
struct SnippetsSettingsView: View {
    @ObservedObject var library: SnippetLibrary
    @State private var selection: UUID?
    @State private var editingSnippet: Snippet?
    @State private var bundleImportMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(library.all) { snippet in
                    row(snippet).tag(snippet.id)
                }
            }
            Divider()
            toolbar
        }
        .sheet(item: $editingSnippet) { snippet in
            SnippetEditorSheet(
                snippet: snippet,
                onSave: { edited in try? library.add(edited); editingSnippet = nil },
                onCancel: { editingSnippet = nil }
            )
        }
        .alert("Bundle Import", isPresented: Binding(get: { bundleImportMessage != nil }, set: { if !$0 { bundleImportMessage = nil } })) {
            Button("OK") { bundleImportMessage = nil }
        } message: {
            Text(bundleImportMessage ?? "")
        }
    }

    private func row(_ snippet: Snippet) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(snippet.name)
                Text(snippet.trigger).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(snippet.languageIDs.isEmpty ? "All" : snippet.languageIDs.joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary)
            if isBuiltin(snippet) {
                Text("Built-in")
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { edit(snippet) }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            Button { editingSnippet = Snippet(name: "New Snippet", trigger: "", languageIDs: [], body: "") } label: {
                Image(systemName: "plus")
            }
            .help("Add snippet")
            Button { duplicateSelected() } label: { Image(systemName: "plus.square.on.square") }
                .help("Duplicate as editable copy")
                .disabled(selectedSnippet == nil)
            Button { deleteSelected() } label: { Image(systemName: "minus") }
                .help("Delete snippet")
                .disabled(!selectedIsUser)
            Spacer()
            Button("Import Bundle…") { BundleImportRunner.run { bundleImportMessage = $0 } }
            Button("Edit") { if let snippet = selectedSnippet { edit(snippet) } }
                .disabled(!selectedIsUser)
        }
        .buttonStyle(.borderless)
        .padding(8)
    }

    // MARK: - Selection helpers

    private var selectedSnippet: Snippet? { library.all.first { $0.id == selection } }
    private var selectedIsUser: Bool { selectedSnippet.map { !isBuiltin($0) } ?? false }
    private func isBuiltin(_ snippet: Snippet) -> Bool { !library.userSnippets.contains { $0.id == snippet.id } }

    private func edit(_ snippet: Snippet) {
        guard !isBuiltin(snippet) else { return }
        editingSnippet = snippet
    }

    private func duplicateSelected() {
        guard let snippet = selectedSnippet else { return }
        // Fresh UUID → a new user snippet; keeping trigger + languages shadows a builtin.
        editingSnippet = Snippet(name: snippet.name + " Copy", trigger: snippet.trigger, languageIDs: snippet.languageIDs, body: snippet.body)
    }

    private func deleteSelected() {
        guard let snippet = selectedSnippet, !isBuiltin(snippet) else { return }
        try? library.delete(id: snippet.id)
        selection = nil
    }
}

/// Add / edit / duplicate form. Parses the body live and blocks Save on an empty trigger or a
/// parse error so a broken snippet can never be stored.
private struct SnippetEditorSheet: View {
    @State var snippet: Snippet
    let onSave: (Snippet) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Name", text: $snippet.name)
            TextField("Trigger", text: $snippet.trigger)

            DisclosureGroup("Languages: \(snippet.languageIDs.isEmpty ? "All" : snippet.languageIDs.joined(separator: ", "))") {
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(Languages.all) { language in
                            Toggle(language.name, isOn: languageBinding(language.id))
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 150)
            }

            Text("Body").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $snippet.body)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 160)
                .border(.quaternary)

            if let parseError {
                Label(parseError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(snippet) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(snippet.trigger.isEmpty || parseError != nil)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var parseError: String? {
        do {
            _ = try SnippetParser.parse(snippet.body)
            return nil
        } catch SnippetParseError.unbalancedBrace {
            return "Unbalanced brace in snippet body."
        } catch SnippetParseError.invalidStop {
            return "Invalid tab stop (regex transforms aren't supported)."
        } catch {
            return "Couldn't parse snippet body."
        }
    }

    private func languageBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { snippet.languageIDs.contains(id) },
            set: { isOn in
                if isOn {
                    if !snippet.languageIDs.contains(id) { snippet.languageIDs.append(id) }
                } else {
                    snippet.languageIDs.removeAll { $0 == id }
                }
            }
        )
    }
}
