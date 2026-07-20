import SwiftUI

/// Content of the `Window("Welcome", id: FirstRunView.windowID)` scene, opened once from
/// `AppDelegate.applicationDidFinishLaunching` (after `restoreSession`) when
/// `hasSeenDefaultsKey` isn't set yet. States plainly what the app does with your data —
/// no marketing copy, every line a checkable claim (mirrors the Roadmap Phase 3 #7 claims
/// this app must keep true: local-only storage, Sparkle-only network, no analytics).
struct FirstRunView: View {
    /// Scene id for `openWindow(id:)`.
    static let windowID = "first-run-intro"
    /// UserDefaults key for "has this device seen the intro". Public/discoverable so a
    /// future Settings → Privacy control (0.8 Task 5) can clear it to bring the intro
    /// back on request.
    static let hasSeenDefaultsKey = "hasSeenFirstRunIntro"

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appModel = AppModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Welcome to MeatPad")
                .font(.title2.weight(.semibold))

            claim(String(localized: "Notes and settings live on this Mac at \(appModel.storageRootPath) — nothing is uploaded."))
            claim(String(localized: "Commands are real shell scripts. They run only when you invoke them; imported commands ask for confirmation first."))
            claim(String(localized: "Network use is limited to update checks (Sparkle). See Settings → Privacy for details."))
            claim(String(localized: "Code intelligence uses language-server programs already installed on your Mac, running as local processes."))

            HStack {
                Spacer()
                Button("Continue") {
                    UserDefaults.standard.set(true, forKey: Self.hasSeenDefaultsKey)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 440)
    }

    private func claim(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
