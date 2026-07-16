import Foundation

public enum NoteStoreError: Error, Equatable {
    case notFound(UUID)
}

/// Owns the on-disk collection of notes: one `<uuid>.txt` (contents) + `<uuid>.json`
/// (metadata sidecar) per note under `rootURL`. Trashed notes move to `<root>/.trash/`.
@MainActor
public final class NoteStore: ObservableObject {
    private let rootURL: URL
    private let trashURL: URL

    /// Sorted by `modified`, most recent first.
    @Published public private(set) var notes: [Note] = []

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
    }

    public func createNote() throws -> Note {
        let now = Date()
        let note = Note(id: UUID(), languageID: nil, created: now, modified: now, cursor: 0, title: "New Note")
        try write(contents: "", note: note)
        notes.append(note)
        resort()
        return note
    }

    public func contents(of id: UUID) throws -> String {
        let url = textURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw NoteStoreError.notFound(id) }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public func save(id: UUID, contents: String, cursor: Int) throws {
        guard var note = notes.first(where: { $0.id == id }) else { throw NoteStoreError.notFound(id) }
        note.modified = Date()
        note.cursor = cursor
        note.title = Note.title(fromContents: contents)
        try write(contents: contents, note: note)
        updateInMemory(note)
    }

    public func setLanguage(id: UUID, languageID: String?) throws {
        guard var note = notes.first(where: { $0.id == id }) else { throw NoteStoreError.notFound(id) }
        note.languageID = languageID
        try writeSidecar(note)
        updateInMemory(note)
    }

    public func trash(id: UUID) throws {
        guard notes.contains(where: { $0.id == id }) else { throw NoteStoreError.notFound(id) }
        let fm = FileManager.default
        for url in [textURL(for: id), jsonURL(for: id)] where fm.fileExists(atPath: url.path) {
            try fm.moveItem(at: url, to: trashURL.appendingPathComponent(url.lastPathComponent))
        }
        notes.removeAll { $0.id == id }
    }

    public static func defaultRoot() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("MeatPad", isDirectory: true).appendingPathComponent("Notes", isDirectory: true)
    }

    // MARK: - Private

    private static func loadNotes(from rootURL: URL) throws -> [Note] {
        let urls = try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
        let notes = try urls.filter { $0.pathExtension == "json" }.map { url -> Note in
            try decoder.decode(Note.self, from: Data(contentsOf: url))
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
