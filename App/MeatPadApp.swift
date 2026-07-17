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
                Button("Open…") { openProjectPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                OpenRecentCommands(openProject: openProject)
            }
            // Replacing .saveItem removes the system Close (Cmd+W) along with Save et al,
            // so the ONE Cmd+W in the app is our unified item below — it routes to
            // closeTab when a project window with tabs is focused, performClose otherwise.
            // A DEBUG launch assertion in AppDelegate verifies the single-Cmd+W invariant.
            CommandGroup(replacing: .saveItem) { ProjectFileCommands() }
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

        WindowGroup("Project", for: URL.self) { $folderURL in
            if let folderURL {
                ProjectWindow(root: folderURL)
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

        Settings {
            SettingsView()
                .environmentObject(AppModel.shared)
        }
    }

    private func createNote() {
        guard let note = try? AppModel.shared.noteStore.createNote() else { return }
        openWindow(value: note.id)
    }

    /// Directory → open as a project. File → open the file's parent folder as the project
    /// and pre-open the file as a tab (via `AppModel.pendingFileOpen`, consumed by the new
    /// `ProjectViewModel`).
    private func openProjectPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            if url.hasDirectoryPath {
                openProject(url)
            } else {
                AppModel.shared.pendingFileOpen = url
                openProject(url.deletingLastPathComponent())
            }
        }
    }

    private func openProject(_ url: URL) {
        openWindow(value: url)
        AppModel.shared.recordRecentProject(url)
    }

    static func finder(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        NSApp.sendAction(#selector(STTextView.performTextFinderAction(_:)), to: nil, from: item)
    }
}

/// File ▸ Open Recent: MRU project folders from `AppModel`, plus "Clear Menu" once
/// there's anything to clear.
private struct OpenRecentCommands: View {
    @ObservedObject private var appModel = AppModel.shared
    let openProject: (URL) -> Void

    var body: some View {
        Menu("Open Recent") {
            ForEach(appModel.recentProjectPaths, id: \.self) { path in
                Button(URL(fileURLWithPath: path).lastPathComponent) {
                    openProject(URL(fileURLWithPath: path))
                }
            }
            if !appModel.recentProjectPaths.isEmpty {
                Divider()
                Button("Clear Menu") { appModel.clearRecentProjects() }
            }
        }
    }
}

/// Save + the app's single, unified Cmd+W. Save targets the focused project window's
/// selected tab (disabled otherwise). Cmd+W is one always-enabled item that routes:
/// focused project window with tabs → close the selected tab (with dirty guard);
/// anything else → performClose on the key window, i.e. the standard Close behaviour
/// note windows had before. One binding, deterministic — never two competing items.
private struct ProjectFileCommands: View {
    @FocusedValue(\.projectViewModel) private var project

    private var hasTabs: Bool { project?.hasTabs == true }

    var body: some View {
        Button("Save") { project?.saveSelectedTab() }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!hasTabs)
        Button(hasTabs ? "Close Tab" : "Close") {
            if let project, project.hasTabs {
                project.requestCloseSelectedTab()
            } else {
                NSApp.keyWindow?.performClose(nil)
            }
        }
        .keyboardShortcut("w", modifiers: .command)
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

        #if DEBUG
        // Invariant behind the unified Cmd+W: replacing .saveItem must have removed the
        // system Close item, leaving exactly one plain-Cmd+W binding in the whole menu
        // bar (Close All is Option+Cmd+W and doesn't count). Delayed a beat so SwiftUI
        // has finished building the menu.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            func plainCmdW(in menu: NSMenu) -> [NSMenuItem] {
                menu.items.flatMap { item -> [NSMenuItem] in
                    var found = item.submenu.map(plainCmdW(in:)) ?? []
                    if item.keyEquivalent == "w", item.keyEquivalentModifierMask == .command {
                        found.append(item)
                    }
                    return found
                }
            }
            let items = NSApp.mainMenu.map(plainCmdW(in:)) ?? []
            assert(items.count == 1, "Expected exactly one Cmd+W menu item, found: \(items.map(\.title))")
        }
        #endif
    }

    /// Guard quit against unsaved *file* documents (notes autosave and flush on their own
    /// `willTerminate` path, untouched). One summary alert covers all dirty files.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirty = EditorRegistry.shared.allFileViewModels().filter { $0.isDirty }
        guard !dirty.isEmpty else { return .terminateNow }

        let alert = NSAlert()
        let count = dirty.count
        alert.messageText = count == 1
            ? "1 document has unsaved changes."
            : "\(count) documents have unsaved changes."
        alert.informativeText = "Do you want to save your changes before quitting?"
        alert.addButton(withTitle: "Save All")
        alert.addButton(withTitle: "Discard All")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // Any save failure (disk full, read-only…) cancels the quit so nothing is
            // silently lost; the helper names the files that couldn't be written.
            return FileEditorViewModel.saveAllReportingFailures(dirty) ? .terminateNow : .terminateCancel
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.saveSessionNow()
    }
}
