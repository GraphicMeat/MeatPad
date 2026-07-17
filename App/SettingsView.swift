import SwiftUI
import MeatPadKit

/// `Settings` scene: General (theme, font, wrap) + Snippets. Commands (Task 9) and Themes
/// (Task 10) tabs are intentionally not added yet.
struct SettingsView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            SnippetsSettingsView(library: appModel.snippetLibrary)
                .tabItem { Label("Snippets", systemImage: "text.badge.plus") }
        }
        .frame(width: 540, height: 460)
    }
}

/// Theme, font size, soft wrap — all `@Published` on `AppModel` and persisted there, so
/// changes apply live to every open editor.
private struct GeneralSettingsView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        Form {
            // Theme isn't Hashable, so the picker binds on its id string instead of the
            // struct itself.
            Picker("Theme", selection: themeIDBinding) {
                ForEach(BuiltinThemes.all) { theme in
                    Text(theme.name).tag(theme.id)
                }
            }

            Stepper(value: $appModel.fontSize, in: 10...24) {
                Text("Font Size: \(Int(appModel.fontSize))")
            }

            Toggle("Soft Wrap", isOn: $appModel.softWrap)
        }
        .padding(20)
    }

    private var themeIDBinding: Binding<String> {
        Binding(
            get: { appModel.theme.id },
            set: { newID in
                guard let theme = BuiltinThemes.all.first(where: { $0.id == newID }) else { return }
                appModel.theme = theme
            }
        )
    }
}
