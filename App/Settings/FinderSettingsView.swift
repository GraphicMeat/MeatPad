import SwiftUI
import AppKit
import FinderSync
import MeatPadKit

/// Settings ▸ Finder: the "New … File" items MeatPad's Finder Sync extension adds to Finder's
/// right-click menu, what happens after a file is created, and whether the extension is on.
/// Edits are saved to `finder.menu` at once, and the extension reads that on every right-click.
struct FinderSettingsView: View {
    @ObservedObject private var settings = FinderMenuSettings.shared
    @State private var extensionEnabled = FIFinderSyncController.isExtensionEnabled

    var body: some View {
        ZStack {
            AmbientGlassBackground()
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Finder Menu")
                        .font(.title2.weight(.semibold))
                    Text("Choose the new-file items Finder's right-click menu offers.")
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 0) {
                    statusRow
                    Divider().opacity(0.45).padding(.leading, 14)
                    HStack {
                        Label("After creating", systemImage: "doc.badge.plus")
                        Spacer()
                        Picker("After creating", selection: $settings.config.afterCreate) {
                            Text("Open in MeatPad").tag(FinderMenuConfig.AfterCreate.openInMeatPad)
                            Text("Show in Finder").tag(FinderMenuConfig.AfterCreate.showInFinder)
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier("settings.finder.afterCreate")
                    }
                    .padding(14)
                    Divider().opacity(0.45).padding(.leading, 14)
                    Toggle(isOn: $settings.config.groupInSubmenu) {
                        Label("Group under a “New File” submenu", systemImage: "list.bullet.indent")
                    }
                    .padding(14)
                    .accessibilityIdentifier("settings.finder.submenu")

                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(settings.config.actions.enumerated()), id: \.element.id) { index, action in
                                Divider().opacity(0.45).padding(.leading, 14)
                                actionRow(index: index, id: action.id)
                            }
                        }
                    }
                }
                .glassPanel(cornerRadius: 14, shadow: false)

                HStack {
                    Button("Add File Type") {
                        settings.config.actions.append(FinderNewFileAction(title: "", fileExtension: ""))
                    }
                    .accessibilityIdentifier("settings.finder.add")
                    Spacer()
                    Button("Reset to Defaults") { settings.reset() }
                        .accessibilityIdentifier("settings.finder.reset")
                }
            }
            .padding(24)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            extensionEnabled = FIFinderSyncController.isExtensionEnabled
        }
        .onAppear { extensionEnabled = FIFinderSyncController.isExtensionEnabled }
    }

    private var statusRow: some View {
        HStack {
            Label("Finder extension", systemImage: "puzzlepiece.extension")
            Spacer()
            Text(extensionEnabled ? String(localized: "On") : String(localized: "Off in System Settings"))
                .foregroundStyle(extensionEnabled ? Color.secondary : Color.orange)
                .accessibilityIdentifier("settings.finder.status")
            Button("Open System Settings…") {
                FIFinderSyncController.showExtensionManagementInterface()
            }
            .accessibilityIdentifier("settings.finder.openSystemSettings")
        }
        .padding(14)
    }

    /// One action. Bindings look the action up by id, never by a captured index: a row's
    /// getter can still run once after the row above it is deleted.
    private func actionRow(index: Int, id: UUID) -> some View {
        let valid = FinderMenuConfig.sanitizedExtension(value(id, \.fileExtension, default: "")) != nil
        return HStack(spacing: 10) {
            Toggle("Enabled", isOn: binding(id, \.isEnabled, default: false))
                .labelsHidden()
                .accessibilityIdentifier("settings.finder.action.\(index).enabled")
            TextField("Title", text: binding(id, \.title, default: ""))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("settings.finder.action.\(index).title")
            TextField("Extension", text: binding(id, \.fileExtension, default: ""))
                .textFieldStyle(.roundedBorder)
                .foregroundStyle(valid ? Color.primary : Color.red)
                .frame(width: 110)
                .help(valid ? "" : String(localized: "Not a usable extension — this item is left out of the menu."))
                .accessibilityIdentifier("settings.finder.action.\(index).ext")
            Button {
                settings.config.actions.removeAll { $0.id == id }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Delete"))
            .accessibilityLabel(Text("Delete"))
            .accessibilityIdentifier("settings.finder.action.\(index).delete")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func value<T>(_ id: UUID, _ keyPath: KeyPath<FinderNewFileAction, T>, default fallback: T) -> T {
        settings.config.actions.first { $0.id == id }?[keyPath: keyPath] ?? fallback
    }

    private func binding<T>(_ id: UUID, _ keyPath: WritableKeyPath<FinderNewFileAction, T>, default fallback: T) -> Binding<T> {
        Binding(
            get: { value(id, keyPath, default: fallback) },
            set: { newValue in
                guard let i = settings.config.actions.firstIndex(where: { $0.id == id }) else { return }
                settings.config.actions[i][keyPath: keyPath] = newValue
            }
        )
    }
}
