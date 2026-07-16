import SwiftUI
import AppKit
import MeatPadKit

/// Content of the `Window("All Notes", id: "all-notes")` scene: a searchable sidebar
/// of every note plus a detail editor for the selection, reusing the same
/// `NoteEditorViewModel` autosave pipeline as a standalone note window.
struct NotesBrowserWindow: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""
    @State private var selection: UUID?

    private var filtered: [Note] {
        let notes = appModel.noteStore.notes
        guard !query.isEmpty else { return notes }
        return notes.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    @ViewBuilder
    private var sidebar: some View {
        if appModel.noteStore.notes.isEmpty {
            Text("No notes yet")
                .foregroundStyle(.secondary)
        } else {
            List(filtered, selection: $selection) { note in
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.title).lineLimit(1)
                    Text(note.modified, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contextMenu {
                    Button("Open in New Window") { openWindow(value: note.id) }
                    Button("Move to Trash", role: .destructive) { trash(note.id) }
                }
            }
            .searchable(text: $query)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selection, appModel.noteStore.notes.contains(where: { $0.id == selection }) {
            NoteDetailEditor(noteID: selection)
                .id(selection)
        } else {
            Text("Select a note")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func trash(_ id: UUID) {
        try? appModel.noteStore.trash(id: id)
        if selection == id { selection = nil }
    }
}

/// Detail-pane editor for one note, selected from the browser sidebar. Mirrors
/// `NoteWindow`'s autosave wiring; `.id(selection)` on the call site forces a fresh
/// `@StateObject` (and thus a fresh load) whenever the sidebar selection changes.
private struct NoteDetailEditor: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.openWindow) private var openWindow
    @StateObject private var viewModel: NoteEditorViewModel
    private let noteID: UUID

    init(noteID: UUID) {
        self.noteID = noteID
        _viewModel = StateObject(wrappedValue: NoteEditorViewModel(noteID: noteID, store: AppModel.shared.noteStore))
    }

    var body: some View {
        Group {
            if viewModel.exists {
                CodeEditor(
                    text: Binding(get: { viewModel.text }, set: viewModel.textDidChange),
                    language: viewModel.language,
                    theme: appModel.theme,
                    onCursorChange: viewModel.cursorDidChange
                )
            } else {
                Text("This note was deleted.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Open in New Window") { openWindow(value: noteID) }
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
