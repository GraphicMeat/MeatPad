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
                    .keyboardFocusRingOnly()
            }
        }
        .commands {
            CommandGroup(after: .appInfo) { CheckForUpdatesCommand() }
            CommandGroup(replacing: .newItem) {
                Button("New Note") { createNote() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Open…") { openProjectPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("All Notes") { openWindow(id: "all-notes") }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                OpenRecentCommands(openProject: openProject)
            }
            // Replacing .saveItem removes the system Close (Cmd+W) along with Save et al,
            // so the ONE Cmd+W in the app is our unified item below — it routes to
            // closeTab when a project window with tabs is focused, performClose otherwise.
            // A DEBUG launch assertion in AppDelegate verifies the single-Cmd+W invariant.
            CommandGroup(replacing: .saveItem) { ProjectFileCommands() }
            // Empties the default Format menu (Font > Show Fonts is Cmd+T) — this app is
            // plain-text only and never adopts NSFontPanel, so that menu was dead weight
            // and its Cmd+T would otherwise race our quick-open binding below.
            CommandGroup(replacing: .textFormatting) { }
            CommandGroup(replacing: .printItem) { PrintCommand() }
            CommandGroup(after: .toolbar) {
                Menu("Language") { LanguageCommands() }
                QuickOpenCommand()
                ProjectSearchCommand()
            }
            // Route Cmd+F / Cmd+G through the responder chain to STTextView's
            // NSTextFinder integration. It reads the action from the sender's tag.
            CommandGroup(after: .textEditing) {
                SelectNextOccurrenceCommand()
                Button("Find…") { MeatPadApp.finder(.showFindInterface) }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Find Next") { MeatPadApp.finder(.nextMatch) }
                    .keyboardShortcut("g", modifiers: .command)
                Button("Find Previous") { MeatPadApp.finder(.previousMatch) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Divider()
                FoldAllCommands()
            }
            CommandMenu("Commands") {
                SavedCommandItems()
                Divider()
                MacroCommandItems()
                Divider()
                FilterCommandItems()
                Divider()
                InsertSnippetCommands()
            }
            CommandMenu("Navigate") {
                GoToDefinitionCommand()
            }
        }

        WindowGroup("Project", for: URL.self) { $folderURL in
            if let folderURL {
                ProjectWindow(root: folderURL)
                    .keyboardFocusRingOnly()
            }
        }

        Window("All Notes", id: "all-notes") {
            NotesBrowserWindow()
                .environmentObject(AppModel.shared)
                .keyboardFocusRingOnly()
        }

        MenuBarExtra("MeatPad", systemImage: "note.text") {
            MenuBarNotesView()
                .environmentObject(AppModel.shared)
                .keyboardFocusRingOnly()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(AppModel.shared)
                .keyboardFocusRingOnly()
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

/// Check for Updates…, routed to Sparkle's shared updater controller. Disabled in DEBUG so
/// dev builds can't trigger a feed check or offer to install over themselves.
private struct CheckForUpdatesCommand: View {
    var body: some View {
        Button("Check for Updates…") {
            AppModel.shared.updaterController.checkForUpdates(nil)
        }
        #if DEBUG
        .disabled(true)
        #endif
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

/// Cmd+D: multi-caret "Select Next Occurrence" on the focused editor. Same `@FocusedValue`
/// routing as the other editor-command-context items — disabled with no editor focused.
private struct SelectNextOccurrenceCommand: View {
    @FocusedValue(\.editorCommandContext) private var context

    var body: some View {
        Button("Select Next Occurrence") {
            guard let context, let tv = context.textView() else { return }
            MultiCaretController.selectNextOccurrence(in: tv)
        }
        .keyboardShortcut("d", modifiers: .command)
        .disabled(context == nil)
    }
}

/// Cmd+Opt+Shift+Left/Right: fold/unfold every top-level region in the focused editor.
/// Fold/unfold-at-caret (Cmd+Opt+Left/Right) has no menu item — it's intercepted at the raw
/// key-event level in `SnippetTextView.keyDown` (see that file) since editor key-binding
/// chords don't need a menu seam. Fold All / Unfold All aren't caret-relative, so they route
/// through the same `@FocusedValue(\.editorCommandContext)` pattern as the other editor
/// commands here, reaching the focused editor's `FoldController` via
/// `EditorCommandContext.foldAll`/`unfoldAll`.
private struct FoldAllCommands: View {
    @FocusedValue(\.editorCommandContext) private var context

    var body: some View {
        Button("Fold All") { context?.foldAll() }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option, .shift])
            .disabled(context == nil)
        Button("Unfold All") { context?.unfoldAll() }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option, .shift])
            .disabled(context == nil)
    }
}

/// ⌃⌘J: Go to Definition (0.7 LSP plan Task 4) — Xcode's own shortcut for the same
/// feature. Picked because this app has no Control-modifier shortcuts yet (grepped every
/// `.keyboardShortcut` in this file first — the taken combos are all plain-Cmd or
/// Cmd+Option/Shift), so it's guaranteed conflict-free, and reusing prior art beats
/// inventing a new one. The mouse-driven trigger is Cmd+click (`SnippetTextView
/// .onDefinitionClick`, wired in `CodeEditor`) — both funnel into the same
/// `ProjectViewModel.goToDefinition`. Disabled with no editor focused or (via
/// `goToDefinitionAvailable`) when the focused editor has no live LSP server for its
/// language — notes never set it, so it's always disabled there.
private struct GoToDefinitionCommand: View {
    @FocusedValue(\.editorCommandContext) private var context

    var body: some View {
        Button("Go to Definition") { context?.goToDefinition() }
            .keyboardShortcut("j", modifiers: [.command, .control])
            .disabled(context?.goToDefinitionAvailable != true)
    }
}

/// Cmd+P: prints the focused editor's document. Disabled with no editor focused —
/// same `@FocusedValue` routing as the other editor-command-context menu items.
private struct PrintCommand: View {
    @FocusedValue(\.editorCommandContext) private var context

    var body: some View {
        Button("Print…") { context.map(PrintController.print) }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(context == nil)
    }
}

/// Cmd+T: toggles the quick-open panel on the focused project window. Same
/// `@FocusedValue` routing as Save/Close — disabled with no project window frontmost.
private struct QuickOpenCommand: View {
    @FocusedValue(\.projectViewModel) private var project

    var body: some View {
        Button("Quick Open…") { project?.quickOpenVisible.toggle() }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(project == nil)
    }
}

/// Cmd+Shift+F: switches the focused project window's sidebar to Search and focuses its
/// query field. Pressing it again while already on Search just refocuses the field (via
/// `requestFocus`'s token bump — a plain sidebar-mode assignment can't retrigger that).
private struct ProjectSearchCommand: View {
    @FocusedValue(\.projectViewModel) private var project
    @FocusedValue(\.projectSearchViewModel) private var search

    var body: some View {
        Button("Find in Project…") {
            project?.sidebarMode = .search
            search?.requestFocus()
        }
        .keyboardShortcut("f", modifiers: [.command, .shift])
        .disabled(project == nil)
    }
}

/// Commands ▸ saved shell commands scoped to the focused editor's language. Disabled
/// when no editor is focused or a command is already running.
private struct SavedCommandItems: View {
    @FocusedValue(\.editorCommandContext) private var context
    @ObservedObject private var store = AppModel.shared.commandStore
    @ObservedObject private var executor = AppModel.shared.commandExecutor

    var body: some View {
        let commands = store.commands(forLanguageID: context?.languageID)
        if commands.isEmpty {
            Button("No Commands") {}.disabled(true)
        } else {
            ForEach(commands) { command in
                if let shortcut = ShortcutParser.parse(command.keyEquivalent) {
                    Button(command.name) { run(command) }
                        .keyboardShortcut(shortcut)
                        .disabled(context == nil || executor.isRunning)
                } else {
                    Button(command.name) { run(command) }
                        .disabled(context == nil || executor.isRunning)
                }
            }
        }
    }

    private func run(_ command: SavedCommand) {
        guard let context else { return }
        AppModel.shared.commandExecutor.run(command, context: context)
    }
}

/// Commands ▸ macro record/replay: Start/Stop Recording (Cmd+Opt+M), Replay Last Macro
/// (Cmd+Shift+M), Save Last Macro As… (name prompt → `macroStore.add`), and any saved
/// macros listed below (click replays). Replay always targets the focused editor.
private struct MacroCommandItems: View {
    @FocusedValue(\.editorCommandContext) private var context
    @ObservedObject private var controller = AppModel.shared.macroController
    @ObservedObject private var store = AppModel.shared.macroStore

    var body: some View {
        Button(controller.isRecording ? "Stop Recording" : "Start Recording Macro") {
            controller.isRecording ? controller.stopRecording() : controller.startRecording()
        }
        .keyboardShortcut("m", modifiers: [.command, .option])

        Button("Replay Last Macro") { replay(controller.lastMacro) }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(controller.lastMacro.isEmpty || context == nil || controller.isRecording)

        Button("Save Last Macro As…") { promptSaveLastMacro() }
            .disabled(controller.lastMacro.isEmpty)

        if !store.macros.isEmpty {
            Divider()
            ForEach(store.macros) { macro in
                Button(macro.name) { replay(macro.events) }
                    .disabled(context == nil || controller.isRecording)
            }
        }
    }

    private func replay(_ events: [KeyEventRecord]) {
        guard let context, let textView = context.textView() else { return }
        controller.replay(events, into: textView)
    }

    /// Blocking `NSAlert` + accessory text field — same modal style the rest of the app
    /// uses for one-off prompts (see `ProjectViewModel`'s save/close alerts); no sheet
    /// plumbing needed since this isn't tied to any particular window.
    private func promptSaveLastMacro() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Save Macro As")
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = String(localized: "Macro Name")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            try store.add(Macro(name: name, events: controller.lastMacro))
        } catch {
            // No window/sheet hosts this command-menu item, so a SwiftUI `.alert` has
            // nothing to attach to — same blocking-`NSAlert` style as the prompt above
            // and `ProjectViewModel.presentError`.
            let errorAlert = NSAlert()
            errorAlert.messageText = String(localized: "Couldn't Save Macro")
            errorAlert.informativeText = error.localizedDescription
            errorAlert.addButton(withTitle: String(localized: "OK"))
            errorAlert.runModal()
        }
    }
}

/// Filter Through Command… (Cmd+Opt+R) + Cancel Command while one runs. The filter
/// request routes through the executor's `filterContext`; the focused window's
/// `.sheet` picks it up by host id.
private struct FilterCommandItems: View {
    @FocusedValue(\.editorCommandContext) private var context
    @ObservedObject private var executor = AppModel.shared.commandExecutor

    var body: some View {
        Button("Filter Through Command…") { executor.filterContext = context }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(context == nil)
        Button("Cancel Command") { executor.cancel() }
            .disabled(!executor.isRunning)
    }
}

/// Commands ▸ Insert Snippet: the snippets in scope for the focused editor's language,
/// name-sorted. Selecting one expands it at the caret exactly like a Tab trigger (starting a
/// session). Disabled when no editor is focused.
private struct InsertSnippetCommands: View {
    @FocusedValue(\.snippetInsertion) private var insertion
    @ObservedObject private var appModel = AppModel.shared

    var body: some View {
        Menu("Insert Snippet") {
            if let insertion {
                let snippets = appModel.snippetLibrary.snippets(forLanguageID: insertion.languageID)
                if snippets.isEmpty {
                    Button("No Snippets") {}.disabled(true)
                } else {
                    ForEach(snippets) { snippet in
                        Button(snippet.name) { insertion.insert(snippet) }
                    }
                }
            }
        }
        .disabled(insertion == nil)
    }
}

/// "Automatic" + every registered language, checkmark on whichever applies to the
/// focused note window. Disabled entirely when no note window is frontmost.
private struct LanguageCommands: View {
    @FocusedValue(\.noteEditor) private var editor

    var body: some View {
        Button(label(for: nil, name: String(localized: "Automatic"))) { editor?.setLanguage(nil) }
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
    ///
    /// Once the save-or-discard decision is settled, quit still isn't necessarily ready to
    /// proceed: any open project may have live LSP server processes, and those need to be
    /// asked to shut down and actually reaped before the app exits (see
    /// `AppModel.shutdownAllProjectLSPManagersAndWait`). When there's nothing to wait for
    /// this returns `.terminateNow` exactly as before; otherwise it holds termination open
    /// with `.terminateLater` and replies once shutdown (bounded by its own timeout, so a
    /// hung server can't hang quitting the app) completes.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirty = EditorRegistry.shared.allFileViewModels().filter { $0.isDirty }
        if !dirty.isEmpty {
            let alert = NSAlert()
            let count = dirty.count
            alert.messageText = count == 1
                ? String(localized: "1 document has unsaved changes.")
                : String(localized: "\(count) documents have unsaved changes.")
            alert.informativeText = String(localized: "Do you want to save your changes before quitting?")
            alert.addButton(withTitle: String(localized: "Save All"))
            alert.addButton(withTitle: String(localized: "Discard All"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                // Any save failure (disk full, read-only…) cancels the quit so nothing is
                // silently lost; the helper names the files that couldn't be written.
                guard FileEditorViewModel.saveAllReportingFailures(dirty) else { return .terminateCancel }
            case .alertSecondButtonReturn:
                break // discard — fall through to the LSP-aware terminate decision below
            default:
                return .terminateCancel
            }
        }

        guard AppModel.shared.hasOpenProjectWindows else { return .terminateNow }
        Task {
            await AppModel.shared.shutdownAllProjectLSPManagersAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.saveSessionNow()
    }
}
