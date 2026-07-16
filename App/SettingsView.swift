import SwiftUI
import MeatPadKit

/// `Settings` scene content: theme, font size, soft wrap. All three are `@Published` on
/// `AppModel` and persisted there, so changes apply live to every open editor.
struct SettingsView: View {
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
        .frame(width: 360)
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
