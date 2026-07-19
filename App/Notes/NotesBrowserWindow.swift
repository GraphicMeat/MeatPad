import SwiftUI
import AppKit
import MeatPadKit

/// Content of the `Window("All Notes", id: "all-notes")` scene: a searchable sidebar
/// of every note plus a detail editor for the selection, reusing the same
/// `NoteEditorViewModel` autosave pipeline as a standalone note window.
struct NotesBrowserWindow: View {
    // Observed directly: nested ObservableObject changes don't propagate through
    // AppModel's @EnvironmentObject, so the list would go stale on create/trash/save.
    @ObservedObject private var noteStore = AppModel.shared.noteStore
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""
    @State private var selection: UUID?

    private var filtered: [Note] {
        let notes = noteStore.notes
        guard !query.isEmpty else { return notes }
        return notes.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .background { AmbientGlassBackground() }
        .frame(minWidth: 720, minHeight: 480)
        .onAppear { AppModel.shared.browserWindowDidAppear() }
        .onDisappear { AppModel.shared.browserWindowDidDisappear() }
    }

    @ViewBuilder
    private var sidebar: some View {
        if noteStore.notes.isEmpty {
            Text("No notes yet")
                .foregroundStyle(.secondary)
        } else {
            List(filtered, selection: $selection) { note in
                HStack(spacing: 9) {
                    Image(systemName: "note.text")
                        .foregroundStyle(MeatPadGlass.tint.gradient)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.title).lineLimit(1)
                        Text(note.modified, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contextMenu {
                    Button("Open in New Window") { openInNewWindow(note.id) }
                    Button("Move to Trash", role: .destructive) { trash(note.id) }
                }
            }
            .scrollContentBackground(.hidden)
            .overlay {
                if filtered.isEmpty {
                    Text("No matches")
                        .foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selection, noteStore.notes.contains(where: { $0.id == selection }) {
            NoteDetailEditor(noteID: selection) { openInNewWindow(selection) }
                .id(selection)
        } else {
            ZStack {
                AmbientGlassBackground()
                VStack(spacing: 12) {
                    Image(systemName: "note.text")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(MeatPadGlass.tint.gradient)
                    Text("Select a note")
                        .font(.title3.weight(.medium))
                    Text("Your notes stay ready when inspiration strikes.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(26)
                .glassPanel()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Opens a standalone note window for `id`. Safe to do while the same note is still
    /// selected in the browser: both surfaces resolve their view model through
    /// `EditorRegistry`, so this opens a second window onto the *same* `NoteEditorViewModel`
    /// rather than a competing copy — no flush-and-deselect handoff needed.
    private func openInNewWindow(_ id: UUID) {
        openWindow(value: id)
    }

    private func trash(_ id: UUID) {
        try? noteStore.trash(id: id)
        if selection == id { selection = nil }
    }
}

/// Detail-pane editor for one note, selected from the browser sidebar. Mirrors
/// `NoteWindow`'s autosave wiring; `.id(selection)` on the call site forces a fresh
/// `@StateObject` wrapper whenever the sidebar selection changes, but the `EditorRegistry`
/// lookup inside `init` hands back the same live `NoteEditorViewModel` (no re-load) if the
/// note is already open elsewhere — e.g. in a standalone `NoteWindow`.
private struct NoteDetailEditor: View {
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var viewModel: NoteEditorViewModel
    @StateObject private var snippetController = SnippetController(library: AppModel.shared.snippetLibrary)
    @ObservedObject private var executor = AppModel.shared.commandExecutor
    private let onOpenInNewWindow: () -> Void

    init(noteID: UUID, onOpenInNewWindow: @escaping () -> Void) {
        self.onOpenInNewWindow = onOpenInNewWindow
        _viewModel = StateObject(wrappedValue: EditorRegistry.shared.noteViewModel(for: noteID))
    }

    /// Keyed on the per-pane snippet controller — the note VM is registry-shared
    /// across windows and would double-present the filter sheet.
    private var filterSheetShown: Binding<Bool> {
        Binding(
            get: { executor.filterContext?.hostID == AnyHashable(ObjectIdentifier(snippetController)) },
            set: { if !$0 { executor.filterContext = nil } }
        )
    }

    var body: some View {
        Group {
            if viewModel.exists {
                CodeEditor(
                    text: Binding(get: { viewModel.text }, set: viewModel.textDidChange),
                    language: viewModel.language,
                    theme: appModel.theme,
                    fontSize: appModel.fontSize,
                    softWrap: appModel.softWrap,
                    initialCursor: appModel.noteStore.notes.first(where: { $0.id == viewModel.noteID })?.cursor,
                    snippetController: snippetController,
                    onCursorChange: viewModel.cursorDidChange
                )
            } else {
                Text("This note was deleted.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .focusedSceneValue(\.snippetInsertion, SnippetInsertion(languageID: viewModel.language?.id, insert: { snippetController.insert($0) }))
        .focusedSceneValue(\.editorCommandContext, EditorCommandContext.make(
            hostID: ObjectIdentifier(snippetController),
            panelCapable: false,
            textView: snippetController.textView,
            languageID: viewModel.language?.id,
            displayName: viewModel.title
        ))
        .sheet(isPresented: filterSheetShown) {
            if let context = executor.filterContext {
                FilterCommandSheet(context: context, onDismiss: { executor.filterContext = nil })
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Open in New Window", action: onOpenInNewWindow)
            }
        }
        .onAppear { viewModel.load() }
        .onDisappear { viewModel.flush() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            viewModel.flush()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            viewModel.flush()
        }
        .focusedValue(\.noteEditor, viewModel)
    }
}
