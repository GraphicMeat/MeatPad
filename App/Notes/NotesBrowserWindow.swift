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
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.title).lineLimit(1)
                    Text(note.modified, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contextMenu {
                    Button("Open in New Window") { openInNewWindow(note.id) }
                    Button("Move to Trash", role: .destructive) { trash(note.id) }
                }
            }
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
            Text("Select a note")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Opens a standalone note window, first tearing down the browser's detail editor
    /// for that note (clearing the selection flushes + releases its view model via
    /// onDisappear) so only one live editor exists per note in this flow.
    // ponytail: last-writer-wins ceiling remains — a menu-bar row click can still open
    // a NoteWindow for a note currently selected in the browser, giving two live view
    // models on the same file. Upgrade path: a per-note shared VM registry.
    private func openInNewWindow(_ id: UUID) {
        if selection == id { selection = nil }
        openWindow(value: id)
    }

    private func trash(_ id: UUID) {
        try? noteStore.trash(id: id)
        if selection == id { selection = nil }
    }
}

/// Detail-pane editor for one note, selected from the browser sidebar. Mirrors
/// `NoteWindow`'s autosave wiring; `.id(selection)` on the call site forces a fresh
/// `@StateObject` (and thus a fresh load) whenever the sidebar selection changes.
private struct NoteDetailEditor: View {
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var viewModel: NoteEditorViewModel
    private let onOpenInNewWindow: () -> Void

    init(noteID: UUID, onOpenInNewWindow: @escaping () -> Void) {
        self.onOpenInNewWindow = onOpenInNewWindow
        _viewModel = StateObject(wrappedValue: NoteEditorViewModel(noteID: noteID, store: AppModel.shared.noteStore))
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
                // Flush before handing off so the standalone window loads the latest
                // contents from disk, not a stale pre-debounce snapshot.
                Button("Open in New Window") {
                    viewModel.flush()
                    onOpenInNewWindow()
                }
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
