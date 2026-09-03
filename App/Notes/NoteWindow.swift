import SwiftUI
import AppKit
import MeatPadKit

/// One note per window: no dirty markers, no save dialogs. The window title tracks the
/// note's derived title live; content autosaves silently in the background.
struct NoteWindow: View {
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var viewModel: NoteEditorViewModel
    @StateObject private var snippetController = SnippetController(library: AppModel.shared.snippetLibrary)
    @ObservedObject private var executor = AppModel.shared.commandExecutor

    init(noteID: UUID) {
        _viewModel = StateObject(wrappedValue: EditorRegistry.shared.noteViewModel(for: noteID))
    }

    /// True while the executor's filter request targets this note window's editor.
    /// Keyed on the per-window snippet controller, NOT the note view model — the
    /// registry shares one VM per note across windows, which would double-present.
    private var filterSheetShown: Binding<Bool> {
        Binding(
            get: { executor.filterContext?.hostID == AnyHashable(ObjectIdentifier(snippetController)) },
            set: { if !$0 { executor.filterContext = nil } }
        )
    }

    /// The executor's untrusted-command prompt, filtered to this window the same way
    /// `filterSheetShown` is — keyed on `snippetController`, not the shared note view model.
    private var trustRequestForWindow: Binding<CommandTrustRequest?> {
        Binding(
            get: { executor.trustRequest?.context.hostID == AnyHashable(ObjectIdentifier(snippetController)) ? executor.trustRequest : nil },
            set: { if $0 == nil { executor.trustRequest = nil } }
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
                    onCursorChange: viewModel.cursorDidChange,
                    onImageImport: { items in
                        for item in items { _ = try? appModel.noteStore.addAttachment(id: viewModel.noteID, data: item.data, ext: item.ext) }
                        return !items.isEmpty
                    }
                )
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        NoteAttachmentsBar(store: appModel.noteStore, noteID: viewModel.noteID)
                        EditorStatusBar(
                            text: viewModel.text,
                            cursor: viewModel.cursor,
                            languageOverride: viewModel.languageOverride,
                            language: viewModel.language,
                            onSelectLanguage: viewModel.setLanguage
                        )
                    }
                }
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
        .sheet(item: trustRequestForWindow) { request in
            CommandTrustSheet(
                request: request,
                onCancel: { executor.trustRequest = nil },
                onRunOnce: {
                    executor.trustRequest = nil
                    executor.runOnce(request.command, context: request.context)
                },
                onTrustAndRun: {
                    executor.trustRequest = nil
                    executor.trustAndRun(request.command, context: request.context)
                }
            )
        }
        .frame(minWidth: 640, minHeight: 420)
        .navigationTitle(viewModel.title)
        .background(WindowAccessor(onWindow: viewModel.attach))
        .onAppear {
            viewModel.load()
            appModel.noteWindowDidAppear(viewModel.noteID)
        }
        .onDisappear { appModel.noteWindowDidDisappear(viewModel.noteID) }
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
