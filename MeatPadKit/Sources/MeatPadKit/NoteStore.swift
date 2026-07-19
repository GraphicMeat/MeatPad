import Foundation

public enum NoteStoreError: Error, Equatable {
    case notFound(UUID)
    case folderExists(String)
    case folderNotFound(String)
    case invalidFolderName
}

/// Owns the on-disk collection of notes: one `<uuid>.txt` (contents) + `<uuid>.json`
/// (metadata sidecar) per note under `rootURL`. Trashed notes move to `<root>/.trash/`.
@MainActor
public final class NoteStore: ObservableObject {
    private let rootURL: URL
    private let trashURL: URL

    /// Sorted by `modified`, most recent first.
    @Published public private(set) var notes: [Note] = []

    /// User-created folders in creation order. The default "Notes" folder is implicit
    /// and never appears here.
    @Published public private(set) var folders: [String] = []

    /// In-memory full-text index, kept in sync with every content-mutating disk write
    /// (never persisted — rebuilt from disk on each launch). Folder ops don't touch
    /// contents, so they don't touch the index either.
    public let searchIndex = NoteSearchIndex()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public init(rootURL: URL) throws {
        self.rootURL = rootURL
        self.trashURL = rootURL.appendingPathComponent(".trash", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: trashURL, withIntermediateDirectories: true)
        notes = try Self.loadNotes(from: rootURL)
        folders = Self.loadFolders(from: foldersURL)
        // Eager: notes are small, and search must work before the user touches anything.
        for note in notes {
            let contents = (try? String(contentsOf: textURL(for: note.id), encoding: .utf8)) ?? ""
            searchIndex.update(id: note.id, contents: contents)
        }
    }

    public func createNote(in folder: String? = nil) throws -> Note {
        let now = Date()
        let note = Note(id: UUID(), languageID: nil, created: now, modified: now, cursor: 0, title: "New Note", folder: folder)
        try write(contents: "", note: note)
        notes.append(note)
        resort()
        searchIndex.update(id: note.id, contents: "")
        return note
    }

    public func contents(of id: UUID) throws -> String {
        guard notes.contains(where: { $0.id == id }) else { throw NoteStoreError.notFound(id) }
        return try String(contentsOf: textURL(for: id), encoding: .utf8)
    }

    public func save(id: UUID, contents: String, cursor: Int) throws {
        guard var note = notes.first(where: { $0.id == id }) else { throw NoteStoreError.notFound(id) }
        note.modified = Date()
        note.cursor = cursor
        note.title = Note.title(fromContents: contents)
        try write(contents: contents, note: note)
        updateInMemory(note)
        searchIndex.update(id: id, contents: contents)
    }

    public func setLanguage(id: UUID, languageID: String?) throws {
        guard var note = notes.first(where: { $0.id == id }) else { throw NoteStoreError.notFound(id) }
        note.languageID = languageID
        try writeSidecar(note)
        updateInMemory(note)
    }

    /// Persists the note window's frame. Sidecar-only: does NOT touch `modified` or
    /// re-sort — moving a window isn't an edit.
    public func setWindowFrame(id: UUID, frame: String?) throws {
        guard var note = notes.first(where: { $0.id == id }) else { throw NoteStoreError.notFound(id) }
        note.windowFrame = frame
        try writeSidecar(note)
        if let idx = notes.firstIndex(where: { $0.id == id }) {
            notes[idx] = note
        }
    }

    public func trash(id: UUID) throws {
        guard notes.contains(where: { $0.id == id }) else { throw NoteStoreError.notFound(id) }
        let fm = FileManager.default
        for url in [textURL(for: id), jsonURL(for: id)] where fm.fileExists(atPath: url.path) {
            try fm.moveItem(at: url, to: trashURL.appendingPathComponent(url.lastPathComponent))
        }
        notes.removeAll { $0.id == id }
        searchIndex.remove(id: id)
    }

    // MARK: - Folders

    public func createFolder(_ name: String) throws {
        let trimmed = try validated(name)
        guard !folders.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            throw NoteStoreError.folderExists(trimmed)
        }
        let updated = folders + [trimmed]
        try saveFolders(updated)
        folders = updated
    }

    /// `old` is matched exact (not case-insensitive) by design — callers pass names
    /// straight from `folders`, so exact match is always correct here.
    public func renameFolder(_ old: String, to new: String) throws {
        guard let idx = folders.firstIndex(of: old) else { throw NoteStoreError.folderNotFound(old) }
        let trimmed = try validated(new)
        // Uniqueness against every OTHER folder — case-change rename of itself is legal.
        guard !folders.enumerated().contains(where: { $0.offset != idx && $0.element.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            throw NoteStoreError.folderExists(trimmed)
        }
        var updated = folders
        updated[idx] = trimmed
        try saveFolders(updated)
        folders = updated
        // Rewrite member sidecars; keep going on individual failures, surface the first
        // at the end (per-note sidecars are the source of truth, reload stays consistent).
        var firstError: Error?
        for var note in notes where note.folder == old {
            note.folder = trimmed
            do {
                try writeSidecar(note)
                if let i = notes.firstIndex(where: { $0.id == note.id }) { notes[i] = note }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    /// `name` is matched exact (not case-insensitive) by design — callers pass names
    /// straight from `folders`, so exact match is always correct here.
    public func deleteFolder(_ name: String) throws {
        guard folders.contains(name) else { throw NoteStoreError.folderNotFound(name) }
        var firstError: Error?
        for id in notes.filter({ $0.folder == name }).map(\.id) {
            do { try trash(id: id) } catch { if firstError == nil { firstError = error } }
        }
        let updated = folders.filter { $0 != name }
        try saveFolders(updated)
        folders = updated
        if let firstError { throw firstError }
    }

    /// Moves a note to a folder (nil = default). Sidecar-only: does NOT touch `modified`
    /// or re-sort — organizing isn't an edit.
    public func move(id: UUID, to folder: String?) throws {
        guard var note = notes.first(where: { $0.id == id }) else { throw NoteStoreError.notFound(id) }
        if let folder { guard folders.contains(folder) else { throw NoteStoreError.folderNotFound(folder) } }
        note.folder = folder
        try writeSidecar(note)
        if let idx = notes.firstIndex(where: { $0.id == id }) {
            notes[idx] = note
        }
    }

    /// Trims, rejects empty and the reserved default-folder name.
    private func validated(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.caseInsensitiveCompare("Notes") != .orderedSame else {
            throw NoteStoreError.invalidFolderName
        }
        return trimmed
    }

    private var foldersURL: URL {
        rootURL.appendingPathComponent("folders.json")
    }

    /// Self-healing: missing or corrupt folders.json = no user folders. Notes referencing
    /// unknown folders keep their sidecar `folder` value (a restored file re-adopts them);
    /// the UI treats them as default-folder.
    private static func loadFolders(from url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let names = try? decoder.decode([String].self, from: data) else { return [] }
        return names
    }

    private func saveFolders(_ list: [String]) throws {
        try Self.encoder.encode(list).write(to: foldersURL, options: .atomic)
    }

    /// UserDefaults key for an absolute-path override of the storage base (the `MeatPad`
    /// directory that `Notes`/`Snippets`/`Commands`/`Macros`/`Themes`/`session.json` all
    /// live under). Public so app code (Settings relocation flow) writes the same key
    /// `defaultRoot` reads.
    public static let storageRootOverrideKey = "meatpad.storageRootOverride"

    /// `~/Library/Application Support/MeatPad/Notes`, unless `storageRootOverrideKey` is
    /// set in `defaults` to an absolute path that exists as a directory — then
    /// `<override>/Notes`. `defaults` is an injectable seam for tests; production always
    /// uses `.standard`. A missing/stale override path falls back silently rather than
    /// failing app launch.
    public static func defaultRoot(defaults: UserDefaults = .standard) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var base = appSupport.appendingPathComponent("MeatPad", isDirectory: true)
        if let override = defaults.string(forKey: storageRootOverrideKey) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: override, isDirectory: &isDirectory), isDirectory.boolValue {
                base = URL(fileURLWithPath: override, isDirectory: true)
            }
        }
        return base.appendingPathComponent("Notes", isDirectory: true)
    }

    // MARK: - Private

    /// Self-healing load: a single corrupt/missing file must never hide the rest of the
    /// notes ("notes never lost"). Only a failure to read the root directory itself throws.
    private static func loadNotes(from rootURL: URL) throws -> [Note] {
        let fm = FileManager.default
        let urls = try fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)

        // Every note id present on disk, whether it has a txt, a json, or both.
        let ids = Set(urls.compactMap { url -> UUID? in
            guard url.pathExtension == "txt" || url.pathExtension == "json" else { return nil }
            return UUID(uuidString: url.deletingPathExtension().lastPathComponent)
        })

        var notes: [Note] = []
        for id in ids {
            let base = rootURL.appendingPathComponent(id.uuidString)
            let txtURL = base.appendingPathExtension("txt")
            let jsonURL = base.appendingPathExtension("json")

            // Sidecar without contents: create an empty txt so the note stays usable.
            if !fm.fileExists(atPath: txtURL.path) {
                try? Data().write(to: txtURL, options: .atomic)
            }

            if let data = try? Data(contentsOf: jsonURL),
               let note = try? decoder.decode(Note.self, from: data),
               note.id == id {
                notes.append(note)
                continue
            }

            // Corrupt or missing sidecar: regenerate it from the txt on disk.
            let contents = (try? String(contentsOf: txtURL, encoding: .utf8)) ?? ""
            let attributes = try? fm.attributesOfItem(atPath: txtURL.path)
            let note = Note(
                id: id,
                languageID: nil,
                created: attributes?[.creationDate] as? Date ?? Date(),
                modified: attributes?[.modificationDate] as? Date ?? Date(),
                cursor: 0,
                title: Note.title(fromContents: contents)
            )
            if let repaired = try? encoder.encode(note) {
                try? repaired.write(to: jsonURL, options: .atomic)
            }
            notes.append(note)
        }
        return notes.sorted { $0.modified > $1.modified }
    }

    private func textURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString).appendingPathExtension("txt")
    }

    private func jsonURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private func write(contents: String, note: Note) throws {
        try Data(contents.utf8).write(to: textURL(for: note.id), options: .atomic)
        try writeSidecar(note)
    }

    private func writeSidecar(_ note: Note) throws {
        let data = try Self.encoder.encode(note)
        try data.write(to: jsonURL(for: note.id), options: .atomic)
    }

    private func updateInMemory(_ note: Note) {
        if let idx = notes.firstIndex(where: { $0.id == note.id }) {
            notes[idx] = note
        } else {
            notes.append(note)
        }
        resort()
    }

    private func resort() {
        notes.sort { $0.modified > $1.modified }
    }
}
