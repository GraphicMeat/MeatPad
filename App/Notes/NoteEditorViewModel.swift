import Foundation
import AppKit
import MeatPadKit

/// Owns one open note's editing state: loads contents on appear, debounces autosave
/// (1s) on every edit, and flushes immediately on window close / app resign-active /
/// app termination so nothing is lost. No dirty markers, no save dialogs — the file on
/// disk is always the source of truth.
@MainActor
final class NoteEditorViewModel: ObservableObject {
    let noteID: UUID
    // ponytail: `exists` only re-checks on the next save/setLanguage attempt (both
    // already guard on the store's notFound error), not via a live subscription to
    // store.notes. An idle window whose note gets trashed elsewhere won't flip to the
    // empty state until the user next types or moves the cursor. Add a Combine sink on
    // store.$notes here if that idle case needs to be instant.
    @Published private(set) var exists: Bool
    @Published var text: String = ""
    @Published private(set) var languageOverride: String?
    @Published private(set) var title: String = "New Note"

    private let store: NoteStore
    private let debouncer = Debouncer(delay: 1)
    private var cursor: Int = 0
    private var loaded = false
    private var closeObserver: NSObjectProtocol?

    /// `languageOverride` wins; otherwise re-detected live from contents. Detection is
    /// cheap enough to run on every keystroke rather than debouncing it separately.
    var language: Language? {
        if let languageOverride { return Languages.byID(languageOverride) }
        return LanguageDetector.detect(filename: nil, contents: text)
    }

    init(noteID: UUID, store: NoteStore) {
        self.noteID = noteID
        self.store = store
        self.exists = store.notes.contains { $0.id == noteID }
    }

    deinit {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }

    /// Loads the note's contents once, on the editor's first appearance.
    func load() {
        guard !loaded, exists else { return }
        loaded = true
        guard let note = store.notes.first(where: { $0.id == noteID }) else {
            exists = false
            return
        }
        languageOverride = note.languageID
        title = note.title
        cursor = note.cursor
        text = (try? store.contents(of: noteID)) ?? ""
    }

    func textDidChange(_ newText: String) {
        text = newText
        title = Note.title(fromContents: newText)
        scheduleSave()
    }

    func cursorDidChange(_ location: Int) {
        cursor = location
        scheduleSave()
    }

    func setLanguage(_ id: String?) {
        languageOverride = id
        do {
            try store.setLanguage(id: noteID, languageID: id)
        } catch {
            // Note was trashed elsewhere while this window was open. Fall back to the
            // empty state instead of crashing.
            exists = false
        }
    }

    /// Flushes any pending autosave immediately. Called on window close, app
    /// resign-active, and app termination — the moments an in-flight debounce could
    /// otherwise lose the last second of edits.
    func flush() {
        debouncer.flush()
    }

    /// Observes this note's hosting window so closing it flushes the pending autosave
    /// instead of waiting out the debounce.
    func attach(window: NSWindow) {
        guard closeObserver == nil else { return }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    private func scheduleSave() {
        guard exists else { return }
        debouncer.call { [weak self] in self?.performSave() }
    }

    private func performSave() {
        do {
            try store.save(id: noteID, contents: text, cursor: cursor)
        } catch {
            // Trashed elsewhere while this window was open — stop trying to save it.
            exists = false
        }
    }
}
