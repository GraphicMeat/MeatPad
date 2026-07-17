import SwiftUI
import MeatPadKit

/// `Settings` scene: General (font, wrap) + Themes + Snippets + Commands.
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
        }
        .frame(width: 640, height: 560)
    }
}

/// Font size, soft wrap — `@Published` on `AppModel` and persisted there, so changes
/// apply live to every open editor. Theme selection lives in the Themes tab now.
private struct GeneralSettingsView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        Form {
            Stepper(value: $appModel.fontSize, in: 10...24) {
                Text("Font Size: \(Int(appModel.fontSize))")
            }

            Toggle("Soft Wrap", isOn: $appModel.softWrap)
        }
        .padding(20)
    }
}
