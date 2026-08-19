import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MeatPadKit

/// Settings ▸ Commands: the saved shell command library. Mirrors the Snippets pane:
/// table + add/duplicate/delete toolbar + editor sheet. Write failures surface as alerts.
struct CommandsSettingsView: View {
    @ObservedObject var store: CommandStore
    @State private var selection: UUID?
    @State private var editingCommand: SavedCommand?
    @State private var storeError: String?
    @State private var bundleImportMessage: String?

    /// Plain-Cmd shortcuts the system menu already owns; a command claiming one still
    /// works from the menu (TextMate tradition) but gets a warning badge here.
    private static let clashingShortcuts: Set<String> = ["cmd+s", "cmd+w", "cmd+q", "cmd+t", "cmd+o", "cmd+n", "cmd+f"]

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(store.commands) { command in
                    row(command).tag(command.id)
                }
            }
            Divider()
            toolbar
        }
        .sheet(item: $editingCommand) { command in
            CommandEditorSheet(
                command: command,
                onSave: { edited in
                    do { try store.add(edited); editingCommand = nil } catch { storeError = "\(error)" }
                },
                onCancel: { editingCommand = nil }
            )
        }
        .alert("Couldn't Save Command", isPresented: Binding(get: { storeError != nil }, set: { if !$0 { storeError = nil } })) {
            Button("OK") { storeError = nil }
        } message: {
            Text(storeError ?? "")
        }
        .alert("Bundle Import", isPresented: Binding(get: { bundleImportMessage != nil }, set: { if !$0 { bundleImportMessage = nil } })) {
            Button("OK") { bundleImportMessage = nil }
        } message: {
            Text(bundleImportMessage ?? "")
        }
    }

    private func row(_ command: SavedCommand) -> some View {
        HStack {
            trustIcon(command)
            VStack(alignment: .leading, spacing: 2) {
                Text(command.name)
                if command.trusted {
                    Text(command.script).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("Imported — not yet trusted. Runs will ask for confirmation.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            if let key = command.keyEquivalent, !key.isEmpty {
                if Self.clashingShortcuts.contains(key.lowercased()) {
                    Label(key, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .help("Clashes with a standard menu shortcut")
                } else {
                    Text(key).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(command.languageIDs.isEmpty ? String(localized: "All") : command.languageIDs.joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { editingCommand = command }
        .contextMenu {
            if command.trusted {
                Button("Revoke Trust") { setTrusted(command, trusted: false) }
            } else {
                Button("Trust") { setTrusted(command, trusted: true) }
            }
        }
    }

    private func trustIcon(_ command: SavedCommand) -> some View {
        Image(systemName: command.trusted ? "checkmark.shield" : "exclamationmark.shield.fill")
            .foregroundStyle(command.trusted ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
            .help(command.trusted ? "Trusted — runs without confirmation" : "Not yet trusted — will ask before first run")
    }

    private func setTrusted(_ command: SavedCommand, trusted: Bool) {
        var updated = command
        updated.trusted = trusted
        do { try store.update(updated) } catch { storeError = "\(error)" }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            Button {
                editingCommand = SavedCommand(name: String(localized: "New Command"), script: "", input: .selection, output: .replaceSelection)
            } label: { Image(systemName: "plus") }
                .help("Add command")
            Button { duplicateSelected() } label: { Image(systemName: "plus.square.on.square") }
                .help("Duplicate")
                .disabled(selectedCommand == nil)
            Button { deleteSelected() } label: { Image(systemName: "minus") }
                .help("Delete command")
                .disabled(selectedCommand == nil)
            Spacer()
            Button("Import Bundle…") { BundleImportRunner.run { bundleImportMessage = $0 } }
            Button("Edit") { editingCommand = selectedCommand }
                .disabled(selectedCommand == nil)
        }
        .buttonStyle(.borderless)
        .padding(8)
    }

    private var selectedCommand: SavedCommand? { store.commands.first { $0.id == selection } }

    private func duplicateSelected() {
        guard let command = selectedCommand else { return }
        editingCommand = SavedCommand(
            name: String(localized: "\(command.name) Copy"), script: command.script, input: command.input,
            output: command.output, keyEquivalent: nil, languageIDs: command.languageIDs
        )
    }

    private func deleteSelected() {
        guard let command = selectedCommand else { return }
        do { try store.delete(id: command.id); selection = nil } catch { storeError = "\(error)" }
    }
}

/// Add / edit form: script editor, input/output pickers, key equivalent as plain text
/// ("cmd+shift+r"), language multi-select. Save blocked on empty name/script.
private struct CommandEditorSheet: View {
    @State var command: SavedCommand
    let onSave: (SavedCommand) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Name", text: $command.name)
                .ringlessField()

            Text("Script").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $command.script)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120)
                .border(.quaternary)

            Picker("Input", selection: $command.input) {
                Text("None").tag(CommandInput.none)
                Text("Selection").tag(CommandInput.selection)
                Text("Document").tag(CommandInput.document)
            }
            Picker("Output", selection: $command.output) {
                Text("Replace Selection").tag(CommandOutputMode.replaceSelection)
                Text("Insert at Caret").tag(CommandOutputMode.insertAtCaret)
                Text("New Note").tag(CommandOutputMode.newNote)
                Text("Output Panel").tag(CommandOutputMode.outputPanel)
            }

            TextField("Key Equivalent (e.g. cmd+shift+r)", text: keyEquivalentBinding)
                .ringlessField()
            if let key = command.keyEquivalent, !key.isEmpty, ShortcutParser.parse(key) == nil {
                Label("Not a valid shortcut — the command will have no key.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.caption)
            }

            HStack {
                TextField("Timeout (seconds, default 30)", text: timeoutBinding)
                    .ringlessField()
                    .frame(width: 200)
                Toggle("Restricted environment", isOn: $command.restrictedEnvironment)
                    .help("Only TM_* variables plus PATH/HOME/SHELL/LANG/TMPDIR — not the app's full environment.")
            }

            DisclosureGroup("Languages: \(command.languageIDs.isEmpty ? String(localized: "All") : command.languageIDs.joined(separator: ", "))") {
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

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(command) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(command.name.trimmingCharacters(in: .whitespaces).isEmpty
                              || command.script.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var keyEquivalentBinding: Binding<String> {
        Binding(
            get: { command.keyEquivalent ?? "" },
            set: { command.keyEquivalent = $0.isEmpty ? nil : $0 }
        )
    }

    /// Empty text = nil = `CommandRunner`'s own 30s default; a non-numeric or non-positive
    /// entry is ignored (leaves `timeoutSeconds` at its last valid value) rather than
    /// accepting a 0/negative timeout that would kill the process instantly or never.
    private var timeoutBinding: Binding<String> {
        Binding(
            get: { command.timeoutSeconds.map { String(Int($0)) } ?? "" },
            set: { text in
                if text.isEmpty { command.timeoutSeconds = nil }
                else if let value = Double(text), value > 0 { command.timeoutSeconds = value }
            }
        )
    }

    private func languageBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { command.languageIDs.contains(id) },
            set: { isOn in
                if isOn {
                    if !command.languageIDs.contains(id) { command.languageIDs.append(id) }
                } else {
                    command.languageIDs.removeAll { $0 == id }
                }
            }
        )
    }
}

/// Shared "Import Bundle…" flow for the Snippets and Commands panes. A `.tmbundle` can
/// hold both snippets and commands, so importing one is a single operation that adds
/// every result item to both `AppModel.shared.snippetLibrary` and `.commandStore`,
/// regardless of which pane's toolbar button launched the panel.
@MainActor
enum BundleImportRunner {
    static func run(completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        var types: [UTType] = [.folder]
        if let tmbundle = UTType(filenameExtension: "tmbundle") { types.append(tmbundle) }
        panel.allowedContentTypes = types
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            completion(importAndApply(from: url))
        }
    }

    private static func importAndApply(from url: URL) -> String {
        let result: BundleImportResult
        do {
            result = try BundleImporter.importBundle(at: url)
        } catch {
            return String(localized: "Couldn't import bundle: \(error.localizedDescription)")
        }
        // Store adds are not atomic across the batch — on a mid-batch write failure the
        // earlier items are already persisted, so the message must say what actually landed.
        var addedSnippets = 0, addedCommands = 0
        do {
            for snippet in result.snippets {
                try AppModel.shared.snippetLibrary.add(snippet)
                addedSnippets += 1
            }
            for command in result.commands {
                try AppModel.shared.commandStore.add(command)
                addedCommands += 1
            }
        } catch {
            return String(localized: "Import stopped after \(addedSnippets) of \(result.snippets.count) snippets and \(addedCommands) of \(result.commands.count) commands: \(error.localizedDescription)")
        }
        let skipped = result.skippedSnippets + result.skippedCommands
        // Every imported command lands with `trusted: false` (BundleImporter.importCommand,
        // Task 2) — say so here so "0 commands ran" doesn't look like a silent failure.
        let trustNote = addedCommands > 0
            ? String(localized: " — imported as untrusted; each will ask for confirmation before its first run")
            : ""
        return String(localized: "Imported \(addedSnippets) snippets, \(addedCommands) commands (\(skipped) skipped)\(trustNote)")
    }
}
