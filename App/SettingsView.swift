import SwiftUI
import MeatPadKit

/// `Settings` scene: General (font, wrap) + Themes + Snippets + Commands + Privacy.
struct SettingsView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            ThemesSettingsView(themeStore: appModel.themeStore)
                .tabItem { Label("Themes", systemImage: "paintpalette") }
            SnippetsSettingsView(library: appModel.snippetLibrary)
                .tabItem { Label("Snippets", systemImage: "text.badge.plus") }
            CommandsSettingsView(store: appModel.commandStore)
                .tabItem { Label("Commands", systemImage: "terminal") }
            PrivacySettingsView()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 640, height: 560)
        .background { AmbientGlassBackground() }
    }
}

/// Font size, soft wrap — `@Published` on `AppModel` and persisted there, so changes
/// apply live to every open editor. Theme selection lives in the Themes tab now.
private struct GeneralSettingsView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        ZStack {
            AmbientGlassBackground()
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Editor")
                        .font(.title2.weight(.semibold))
                    Text("Tune MeatPad to match the way you write.")
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 0) {
                    HStack {
                        Label("Font size", systemImage: "textformat.size")
                        Spacer()
                        Stepper(value: $appModel.fontSize, in: 10...24) {
                            Text("\(Int(appModel.fontSize)) pt")
                                .monospacedDigit()
                                .frame(width: 42, alignment: .trailing)
                        }
                    }
                    .padding(14)

                    Divider().opacity(0.45).padding(.leading, 44)

                    Toggle(isOn: $appModel.softWrap) {
                        Label("Soft wrap", systemImage: "arrow.turn.down.right")
                    }
                    .padding(14)
                }
                .glassPanel(cornerRadius: 14, shadow: false)

                Spacer()
            }
            .padding(24)
        }
    }
}
