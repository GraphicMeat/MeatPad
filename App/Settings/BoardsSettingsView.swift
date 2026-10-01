import SwiftUI
import AppKit

/// Settings ▸ Boards: whether the card and menu icons are coloured, and which colour each
/// kind of icon gets. Only colours the user changed are stored (`CardIconPalette`), so
/// "Reset" simply drops a kind's entry and it falls back to its system default.
///
/// Styled like `GeneralSettingsView` — a title, then one glass panel of rows. The panel
/// scrolls: eleven kinds plus the toggle are taller than the fixed settings window.
struct BoardsSettingsView: View {
    @AppStorage(CardIconPalette.enabledKey) private var coloredIcons = false
    @AppStorage(CardIconPalette.colorsKey) private var iconColors = ""

    private var custom: [CardIconKind: String] { CardIconPalette.decode(iconColors) }

    var body: some View {
        let palette = CardIconPalette(enabled: coloredIcons, json: iconColors)
        let custom = palette.custom
        ZStack {
            AmbientGlassBackground()
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Boards")
                        .font(.title2.weight(.semibold))
                    Text("Choose how cards and their menus look.")
                        .foregroundStyle(.secondary)
                }

                ScrollView {
                    VStack(spacing: 0) {
                        Toggle(isOn: $coloredIcons) {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("Colored icons", systemImage: "paintpalette")
                                Text("Tint card and menu icons by kind.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(14)
                        .accessibilityIdentifier("settings.board.coloredIcons")

                        ForEach(CardIconKind.allCases) { kind in
                            Divider().opacity(0.45).padding(.leading, 44)
                            row(kind, palette: palette, isCustom: custom[kind] != nil)
                        }

                        Divider().opacity(0.45).padding(.leading, 44)
                        HStack {
                            Spacer()
                            Button("Reset All Colors") { iconColors = "" }
                                .disabled(custom.isEmpty)
                                .accessibilityIdentifier("settings.board.iconColors.resetAll")
                        }
                        .padding(14)
                    }
                    .glassPanel(cornerRadius: 14, shadow: false)
                }
            }
            .padding(24)
        }
    }

    /// Dimmed and inert while colouring is off: the colours are chosen ahead of switching it
    /// on only by people who flip the toggle first, so the rows say what they are waiting for.
    private func row(_ kind: CardIconKind, palette: CardIconPalette, isCustom: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: kind.symbol)
                .foregroundStyle(Color(nsColor: palette.nsColor(for: kind)))
                .frame(width: 22)
            Text(kind.title)
            Spacer()
            ColorPicker(selection: binding(kind, palette: palette), supportsOpacity: false) {
                Text(kind.title)
            }
            .labelsHidden()
            .accessibilityIdentifier("settings.board.iconColor.\(kind.rawValue)")
            Button {
                var next = custom
                next[kind] = nil
                iconColors = CardIconPalette.encode(next)
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .disabled(!isCustom)
            .help(String(localized: "Reset to Default"))
            .accessibilityLabel(Text("Reset to Default"))
            .accessibilityIdentifier("settings.board.iconColor.reset.\(kind.rawValue)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .disabled(!coloredIcons)
        .opacity(coloredIcons ? 1 : 0.45)
    }

    private func binding(_ kind: CardIconKind, palette: CardIconPalette) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: palette.nsColor(for: kind)) },
            set: { picked in
                var next = custom
                next[kind] = CardIconPalette.hex(picked)
                iconColors = CardIconPalette.encode(next)
            }
        )
    }
}
