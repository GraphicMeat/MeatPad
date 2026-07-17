import Foundation
import MeatPadKit

/// Canonical per-note `NoteEditorViewModel`, shared by every window or pane showing that
/// note (a standalone `NoteWindow` and the browser's detail pane can both display the
/// same note). Handing out the same instance everywhere means there's only ever one
/// in-memory copy of a note's text and one autosave debouncer for it — no more
/// last-writer-wins race between two independent VMs saving the same file.
///
/// Weak-value map: the registry never keeps a VM alive by itself. Once every view that
/// owns a strong reference (each surface's `@StateObject`) is torn down, the entry drops
/// out and the VM's `deinit` (window-observer cleanup) runs normally.
@MainActor
final class EditorRegistry {
    static let shared = EditorRegistry()

    private let table = NSMapTable<NSUUID, NoteEditorViewModel>.strongToWeakObjects()
    private let fileTable = NSMapTable<NSURL, FileEditorViewModel>.strongToWeakObjects()

    private init() {}

    func noteViewModel(for id: UUID) -> NoteEditorViewModel {
        let key = id as NSUUID
        if let existing = table.object(forKey: key) {
            return existing
        }
        let viewModel = NoteEditorViewModel(noteID: id, store: AppModel.shared.noteStore)
        table.setObject(viewModel, forKey: key)
        return viewModel
    }

    /// Canonical per-file VM (same weak-value contract as notes). `nil` only when the
    /// file can't be read on first open (missing/permission) — the caller shows a
    /// placeholder rather than the registry faking an empty document.
    func fileViewModel(for url: URL) -> FileEditorViewModel? {
        let key = url as NSURL
        if let existing = fileTable.object(forKey: key) {
            return existing
        }
        guard let document = try? FileDocumentModel(url: url) else { return nil }
        let viewModel = FileEditorViewModel(document: document)
        fileTable.setObject(viewModel, forKey: key)
        return viewModel
    }

    /// Every live file VM — backs the quit-time dirty sweep. Weak values mean this only
    /// ever contains VMs still held by an open window.
    func allFileViewModels() -> [FileEditorViewModel] {
        (fileTable.objectEnumerator()?.allObjects as? [FileEditorViewModel]) ?? []
    }
}
