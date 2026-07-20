import SwiftUI
import MeatPadKit

/// `Settings` scene: General (font, wrap) + Themes + Snippets + Commands + Privacy.
struct SettingsView: View {
    @EnvironmentObject private var appModel: AppModel

    private var captureSize: CGSize {
        #if DEBUG
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "ScreenshotMode") {
            return CGSize(
                width: max(640, defaults.double(forKey: "ScreenshotWindowWidth")),
                // SwiftUI's macOS Settings scene adds 88 pt of tab/title chrome outside
                // this content frame. Subtract it so the captured outer window is the
                // requested 1440×900 rather than 1440×988.
                height: max(560, defaults.double(forKey: "ScreenshotWindowHeight") - 88)
            )
        }
        #endif
        return CGSize(width: 640, height: 560)
    }

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            ThemesSettingsView(themeStore: appModel.themeStore)
                .tabItem {
                    Label("Themes", systemImage: "paintpalette")
                        .accessibilityIdentifier("settings-themes-tab")
                }
            SnippetsSettingsView(library: appModel.snippetLibrary)
                .tabItem { Label("Snippets", systemImage: "text.badge.plus") }
            CommandsSettingsView(store: appModel.commandStore)
                .tabItem { Label("Commands", systemImage: "terminal") }
            PrivacySettingsView()
                .tabItem {
                    Label("Privacy", systemImage: "hand.raised")
                        .accessibilityIdentifier("settings-privacy-tab")
                }
        }
        .frame(width: captureSize.width, height: captureSize.height)
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
