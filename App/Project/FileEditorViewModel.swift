import Foundation
import Combine
import MeatPadKit

/// Owns one open file's editing state: wraps a `FileDocumentModel` (dirty tracking +
/// explicit save, unlike the silent-autosave note path) and detects its language once at
/// load. Shared per-URL by the tab bar and the editor host via `EditorRegistry`, so a
/// file opened in one project window is one in-memory buffer with one dirty flag.
@MainActor
final class FileEditorViewModel: ObservableObject {
    let document: FileDocumentModel
    /// Detected once from filename + initial contents. Files have a real name/extension,
    /// so unlike notes there's no need to re-sniff on every keystroke.
    let language: Language?

    private var cancellable: AnyCancellable?

    /// Two-way mirror of `document.editedContents`. Reading/writing goes straight through
    /// so there's a single source of truth; the `objectWillChange` re-broadcast below
    /// keeps SwiftUI views (tab dirty dot, editor) in sync with the document's own
    /// publishes (isDirty, revert, save).
    var text: String {
        get { document.editedContents }
        set { document.editedContents = newValue }
    }

    var isDirty: Bool { document.isDirty }

    init(document: FileDocumentModel) {
        self.document = document
        self.language = LanguageDetector.detect(
            filename: document.url.lastPathComponent, contents: document.contents
        )
        // FileDocumentModel is its own ObservableObject; re-emit its changes as ours so
        // views observing the VM refresh on isDirty/contents flips (save, revert, edits).
        cancellable = document.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }

    func save() throws { try document.save() }
    func revert() throws { try document.revert() }
    func checkExternalChange() -> ExternalChange { document.checkExternalChange() }
}
