import SwiftUI
import AppKit
import MeatPadKit
import STTextView

@main
struct MeatPadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // `let _ =` (a declaration, not an expression statement) keeps this side effect
        // out of SceneBuilder's result-building, which otherwise requires every
        // statement in this block to itself produce a `Scene`. Captured on every body
        // evaluation (cheap, idempotent); guaranteed available before
        // `applicationDidFinishLaunching` fires, since SwiftUI builds the scene graph
        // before AppKit's launch delegate callbacks run.
        let _ = { AppModel.shared.openWindowAction = openWindow }()

        WindowGroup("Note", for: UUID.self) { $noteID in
            if let noteID {
                NoteWindow(noteID: noteID)
                    .environmentObject(AppModel.shared)
            }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") { createNote() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Menu("Language") { LanguageCommands() }
            }
            // Route Cmd+F / Cmd+G through the responder chain to STTextView's
            // NSTextFinder integration. It reads the action from the sender's tag.
            CommandGroup(after: .textEditing) {
                Button("Find…") { MeatPadApp.finder(.showFindInterface) }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Find Next") { MeatPadApp.finder(.nextMatch) }
                    .keyboardShortcut("g", modifiers: .command)
                Button("Find Previous") { MeatPadApp.finder(.previousMatch) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
            }
        }

        Window("All Notes", id: "all-notes") {
            NotesBrowserWindow()
                .environmentObject(AppModel.shared)
        }

        MenuBarExtra("MeatPad", systemImage: "note.text") {
            MenuBarNotesView()
                .environmentObject(AppModel.shared)
        }
        .menuBarExtraStyle(.window)
    }

    private func createNote() {
        guard let note = try? AppModel.shared.noteStore.createNote() else { return }
        openWindow(value: note.id)
    }

    static func finder(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        NSApp.sendAction(#selector(STTextView.performTextFinderAction(_:)), to: nil, from: item)
    }
}

/// "Automatic" + every registered language, checkmark on whichever applies to the
/// focused note window. Disabled entirely when no note window is frontmost.
private struct LanguageCommands: View {
    @FocusedValue(\.noteEditor) private var editor

    var body: some View {
        Button(label(for: nil, name: "Automatic")) { editor?.setLanguage(nil) }
            .disabled(editor == nil)
        Divider()
        ForEach(Languages.all) { language in
            Button(label(for: language.id, name: language.name)) {
                editor?.setLanguage(language.id)
            }
            .disabled(editor == nil)
        }
    }

    private func label(for id: String?, name: String) -> String {
        editor?.languageOverride == id ? "✓ \(name)" : name
    }
}

/// Bridges AppKit's launch/terminate lifecycle into session restore. SwiftUI's
/// `WindowGroup(for:)` has its own automatic window-state restoration, which would
/// otherwise race with ours and reopen the same notes a second time; setting
/// `ApplePersistenceIgnoreState` disables AppKit-level restoration entirely so
/// `AppModel`'s session.json is the sole source of restored windows.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.restoreSession()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.saveSessionNow()
    }
}
