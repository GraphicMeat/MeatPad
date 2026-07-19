import Foundation
import AppKit
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
    private let detectedLanguage: Language?
    /// Session-only manual override from the status bar; not persisted.
    @Published var languageOverride: String?

    private var cancellable: AnyCancellable?

    var language: Language? {
        if let languageOverride { return Languages.byID(languageOverride) }
        return detectedLanguage
    }

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
        self.detectedLanguage = LanguageDetector.detect(
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

    /// Saves every VM, collecting failures. All saved → true. Any failure → modal alert
    /// naming the files that couldn't be written, returns false so the caller cancels
    /// whatever destructive step (quit, window close) the save was gating.
    static func saveAllReportingFailures(_ viewModels: [FileEditorViewModel]) -> Bool {
        var failures: [(url: URL, error: Error)] = []
        for vm in viewModels {
            do { try vm.save() } catch { failures.append((vm.document.url, error)) }
        }
        guard !failures.isEmpty else { return true }

        let alert = NSAlert()
        alert.messageText = failures.count == 1
            ? String(localized: "Couldn't save “\(failures[0].url.lastPathComponent)”.")
            : String(localized: "Couldn't save \(failures.count) documents.")
        alert.informativeText = failures
            .map { "\($0.url.lastPathComponent): \($0.error.localizedDescription)" }
            .joined(separator: "\n")
        alert.runModal()
        return false
    }
}
