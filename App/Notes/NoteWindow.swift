import SwiftUI
import AppKit
import MeatPadKit

/// One note per window: no dirty markers, no save dialogs. The window title tracks the
/// note's derived title live; content autosaves silently in the background.
struct NoteWindow: View {
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var viewModel: NoteEditorViewModel

    init(noteID: UUID) {
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
        .frame(minWidth: 640, minHeight: 420)
        .navigationTitle(viewModel.title)
        .background(WindowAccessor(onWindow: viewModel.attach))
        .onAppear { viewModel.load() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            viewModel.flush()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            viewModel.flush()
        }
        .focusedValue(\.noteEditor, viewModel)
    }
}

/// Bridges to the hosting NSWindow so closing it (Cmd+W / red button) flushes the
/// pending autosave immediately instead of waiting out the debounce.
private struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window { onWindow(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct FocusedNoteEditorKey: FocusedValueKey {
    typealias Value = NoteEditorViewModel
}

extension FocusedValues {
    /// The editor view model of the currently focused note window, so the Language menu
    /// command (built once at the App level) can act on whichever window is frontmost.
    var noteEditor: NoteEditorViewModel? {
        get { self[FocusedNoteEditorKey.self] }
        set { self[FocusedNoteEditorKey.self] = newValue }
    }
}
