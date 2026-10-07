import SwiftUI
import MeatPadKit

/// Settings ▸ Terminal: the terminal header's Git menu — its commands, whether each runs or is
/// only typed, and the dividers between them. Drag to reorder. Every edit writes through
/// `GitMenuSettings`, so an open project window's menu has it the next time it opens.
struct TerminalSettingsView: View {
    @ObservedObject private var settings = GitMenuSettings.shared
    @State private var selection: GitMenuItem.ID?
    @FocusState private var focusedCommand: GitMenuItem.ID?

    var body: some View {
        ZStack {
            AmbientGlassBackground()
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Git Menu")
                        .font(.title2.weight(.semibold))
                    Text("The commands in the terminal's Git menu. Run sends a command right away; Type leaves it at the prompt for you to finish.")
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 0) {
                    List(selection: $selection) {
                        ForEach($settings.config.items) { $item in
                            row($item).tag(item.id)
                        }
                        .onMove { settings.config.items.move(fromOffsets: $0, toOffset: $1) }
                    }
                    .scrollContentBackground(.hidden)
                    Divider()
                    bottomBar
                }
                .glassPanel(cornerRadius: 14, shadow: false)
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private func row(_ item: Binding<GitMenuItem>) -> some View {
        if item.wrappedValue.isDivider {
            HStack(spacing: 8) {
                Rectangle().fill(.separator).frame(height: 1)
                Text("Divider")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Rectangle().fill(.separator).frame(height: 1)
            }
            .padding(.vertical, 4)
        } else {
            HStack(spacing: 10) {
                TextField(String(localized: "Command"), text: item.command)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .focused($focusedCommand, equals: item.wrappedValue.id)
                    .accessibilityIdentifier("settings.terminal.gitMenu.command")
                Picker(String(localized: "Mode"), selection: item.runs) {
                    Text("Run").tag(true)
                    Text("Type").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("settings.terminal.gitMenu.mode")
            }
            .padding(.vertical, 2)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 4) {
            Button(action: addCommand) { Label("Command", systemImage: "plus") }
                .help("Add a command")
                .accessibilityIdentifier("settings.terminal.gitMenu.addCommand")
            Button(action: addDivider) { Label("Divider", systemImage: "plus") }
                .help("Add a divider")
                .accessibilityIdentifier("settings.terminal.gitMenu.addDivider")
            Button(action: removeSelected) { Image(systemName: "minus") }
                .help("Remove the selected item")
                .disabled(selection == nil)
                .accessibilityIdentifier("settings.terminal.gitMenu.remove")
            Spacer()
            Button("Reset to Defaults") {
                selection = nil
                settings.reset()
            }
            .accessibilityIdentifier("settings.terminal.gitMenu.reset")
        }
        .buttonStyle(.borderless)
        .padding(8)
    }

    /// A new command starts as `git ` in Type mode, focused, so the user just goes on typing.
    private func addCommand() {
        let item = GitMenuItem.command("git ", runs: false)
        settings.config.items.append(item)
        selection = item.id
        // Next turn: the row's field doesn't exist until the list has drawn it.
        DispatchQueue.main.async { focusedCommand = item.id }
    }

    private func addDivider() {
        let item = GitMenuItem.divider()
        settings.config.items.append(item)
        selection = item.id
    }

    private func removeSelected() {
        guard let selection else { return }
        settings.config.items.removeAll { $0.id == selection }
        self.selection = nil
    }
}
