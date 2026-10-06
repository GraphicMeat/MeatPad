import SwiftUI
import AppKit
import MeatPadKit

/// Settings ▸ File Tree: which items the sidebar's right-click menu shows, the shortcut each
/// displays, and whether rows carry icons. Defaults are VS Code's explorer menu.
struct FileTreeSettingsView: View {
    @ObservedObject private var settings = FileTreeMenuSettings.shared

    var body: some View {
        ZStack {
            AmbientGlassBackground()
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("File Tree Menu")
                        .font(.title2.weight(.semibold))
                    Text("Choose what the right-click menu in the project sidebar offers.")
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 0) {
                    Toggle(isOn: $settings.config.showIcons) {
                        Label("Show icons", systemImage: "photo")
                    }
                    .padding(14)
                    .accessibilityIdentifier("settings.fileTree.showIcons")

                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(FileTreeAction.allCases, id: \.self) { action in
                                Divider().opacity(0.45).padding(.leading, 14)
                                actionRow(action)
                            }
                        }
                    }
                }
                .glassPanel(cornerRadius: 14, shadow: false)

                HStack {
                    Text("Shortcuts show in the menu and work while it is open.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to Defaults") { settings.reset() }
                        .accessibilityIdentifier("settings.fileTree.reset")
                }
            }
            .padding(24)
        }
    }

    private func actionRow(_ action: FileTreeAction) -> some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { settings.config.isVisible(action) },
                set: { settings.config.setVisible($0, for: action) }
            )) {
                Label(action.title, systemImage: action.symbolName)
            }
            .accessibilityIdentifier("settings.fileTree.show.\(action.rawValue)")
            Spacer()
            ShortcutRecorder(
                shortcut: Binding(
                    get: { settings.config.shortcut(for: action) },
                    set: { settings.config.setShortcut($0, for: action) }
                )
            )
            .accessibilityIdentifier("settings.fileTree.shortcut.\(action.rawValue)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// A button showing a shortcut; click it, press the new combination. Esc cancels, a bare
/// Delete clears the shortcut.
private struct ShortcutRecorder: View {
    @Binding var shortcut: FileTreeShortcut?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button { recording ? stop() : start() } label: {
            Text(recording ? String(localized: "Press keys…") : (shortcut?.display ?? String(localized: "None")))
                .monospacedDigit()
                .foregroundStyle(recording ? Color.accentColor : (shortcut == nil ? Color.secondary : Color.primary))
                .frame(minWidth: 84)
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let captured = capture(event) else { return event }
            switch captured {
            case .cancel: break
            case .clear: shortcut = nil
            case .set(let new): shortcut = new
            }
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private enum Captured { case cancel, clear, set(FileTreeShortcut) }

    private func capture(_ event: NSEvent) -> Captured? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: FileTreeShortcut.Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }

        let special: [UInt16: String] = [36: "↩", 51: "⌫", 117: "⌦", 48: "⇥", 49: "␣"]
        if event.keyCode == 53 { return .cancel }
        if event.keyCode == 51, modifiers.isEmpty { return .clear }
        if let glyph = special[event.keyCode] {
            return .set(FileTreeShortcut(key: glyph, modifiers: modifiers))
        }
        guard let key = event.charactersIgnoringModifiers, key.count == 1 else { return nil }
        return .set(FileTreeShortcut(key: key, modifiers: modifiers))
    }
}
