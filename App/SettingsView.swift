import SwiftUI
import MeatPadKit

/// The Settings tabs, by name — so another window can ask for one (the note editor's link
/// paste hint sends the user to General, where the setting it describes lives).
enum SettingsTab: Hashable {
    case general, themes, snippets, commands, privacy
}

/// `Settings` scene: General (font, wrap, links) + Themes + Snippets + Commands + Privacy.
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
        TabView(selection: $appModel.settingsTab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            ThemesSettingsView(themeStore: appModel.themeStore)
                .tabItem {
                    Label("Themes", systemImage: "paintpalette")
                        .accessibilityIdentifier("settings-themes-tab")
                }
                .tag(SettingsTab.themes)
            SnippetsSettingsView(library: appModel.snippetLibrary)
                .tabItem { Label("Snippets", systemImage: "text.badge.plus") }
                .tag(SettingsTab.snippets)
            CommandsSettingsView(store: appModel.commandStore)
                .tabItem { Label("Commands", systemImage: "terminal") }
                .tag(SettingsTab.commands)
            PrivacySettingsView()
                .tabItem {
                    Label("Privacy", systemImage: "hand.raised")
                        .accessibilityIdentifier("settings-privacy-tab")
                }
                .tag(SettingsTab.privacy)
        }
        .frame(width: captureSize.width, height: captureSize.height)
        .background { AmbientGlassBackground() }
    }
}

/// Font size, soft wrap — `@Published` on `AppModel` and persisted there, so changes
/// apply live to every open editor. Theme selection lives in the Themes tab now.
private struct GeneralSettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    // Read by AppDelegate.applicationShouldHandleReopen via UserDefaults — same key.
    @AppStorage("dockClickAction") private var dockClickAction = "allNotes"
    // Read at launch by AppDelegate.applicationWillFinishLaunching via UserDefaults — same key.
    @AppStorage("menuBarOnly") private var menuBarOnly = false

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

                    Divider().opacity(0.45).padding(.leading, 44)

                    HStack {
                        Label("Open links in notes", systemImage: "link")
                        Spacer()
                        Picker("Open links in notes", selection: $appModel.linkActivation) {
                            ForEach(LinkActivation.allCases) { activation in
                                Text(activation.label).tag(activation)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier("settings.linkActivation")
                    }
                    .padding(14)

                    Divider().opacity(0.45).padding(.leading, 44)

                    HStack {
                        Label("Dock icon click", systemImage: "dock.rectangle")
                        Spacer()
                        Picker("Dock icon click", selection: $dockClickAction) {
                            Text("Open All Notes").tag("allNotes")
                            Text("New Note").tag("newNote")
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    .padding(14)
                    .disabled(menuBarOnly)

                    Divider().opacity(0.45).padding(.leading, 44)

                    Toggle(isOn: $menuBarOnly) {
                        Label("Menu bar only (hide Dock icon)", systemImage: "menubar.rectangle")
                    }
                    .padding(14)
                    .onChange(of: menuBarOnly) { _, _ in
                        // Window-aware: with the Settings window still open this stays
                        // .regular; the accessory flip happens when the last window closes.
                        AppDelegate.applyActivationPolicy()
                    }
                }
                .glassPanel(cornerRadius: 14, shadow: false)

                Spacer()
            }
            .padding(24)
        }
    }
}
