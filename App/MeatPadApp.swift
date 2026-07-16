import SwiftUI
import AppKit
import MeatPadKit
import STTextView

@main
struct MeatPadApp: App {
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
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
