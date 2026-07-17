import Foundation

/// Result of comparing the last-known on-disk state against the current one.
public enum ExternalChange: Equatable, Sendable {
    case none
    case changedOnDisk
    case deleted
}

/// Headless state + disk IO for editing a real file. Unlike `NoteStore` (silent
/// autosave), a file has standard dirty tracking and an explicit `save()` — editing
/// only ever touches `editedContents` in memory until the caller saves.
@MainActor
public final class FileDocumentModel: ObservableObject, @MainActor Identifiable {
    public let url: URL
    public var id: URL { url }

    @Published public private(set) var contents: String
    @Published public var editedContents: String {
        didSet { isDirty = editedContents != contents }
    }
    @Published public private(set) var isDirty: Bool = false

    /// Snapshot of the file's modification date as of the last load/save/revert,
    /// used to detect changes made outside this model without auto-reloading.
    private var knownModificationDate: Date?

    public init(url: URL) throws {
        self.url = url
        let loaded = try Self.load(from: url)
        self.contents = loaded
        self.editedContents = loaded
        self.knownModificationDate = Self.modificationDate(of: url)
    }

    public func save() throws {
        try Data(editedContents.utf8).write(to: url, options: .atomic)
        contents = editedContents
        isDirty = false
        knownModificationDate = Self.modificationDate(of: url)
    }

    public func revert() throws {
        let loaded = try Self.load(from: url)
        contents = loaded
        editedContents = loaded
        isDirty = false
        knownModificationDate = Self.modificationDate(of: url)
    }

    public func checkExternalChange() -> ExternalChange {
        guard let currentModificationDate = Self.modificationDate(of: url) else { return .deleted }
        guard let known = knownModificationDate, currentModificationDate > known else { return .none }
        return .changedOnDisk
    }

    // MARK: - Private

    /// Reads UTF-8; a file that isn't valid UTF-8 is decoded lossily rather than
    /// refusing to open (binary detection is the caller's problem, not this model's).
    private static func load(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
