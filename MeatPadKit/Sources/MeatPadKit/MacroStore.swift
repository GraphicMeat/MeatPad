import Foundation

/// A single recorded key event, captured verbatim from `NSEvent` for later replay.
public struct KeyEventRecord: Codable, Equatable, Sendable {
    public var keyCode: UInt16
    /// `NSEvent.ModifierFlags.rawValue` (deviceIndependent bits only).
    public var modifiers: UInt
    public var characters: String
    public var charactersIgnoringModifiers: String

    public init(keyCode: UInt16, modifiers: UInt, characters: String, charactersIgnoringModifiers: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
    }
}

/// A named, replayable sequence of key events, persisted one JSON file per macro
/// (see `MacroStore`).
public struct Macro: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var events: [KeyEventRecord]

    public init(id: UUID = UUID(), name: String, events: [KeyEventRecord]) {
        self.id = id
        self.name = name
        self.events = events
    }
}

public enum MacroStoreError: Error, Equatable {
    case notFound(UUID)
}

/// Owns the user's saved macro collection: one `<uuid>.json` file per macro under
/// `directory`. Same shape as `CommandStore`/`SnippetLibrary`.
@MainActor
public final class MacroStore: ObservableObject {
    private let directory: URL

    @Published public private(set) var macros: [Macro] = []

    private static let decoder = JSONDecoder()
    private static let encoder = JSONEncoder()

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        macros = Self.loadMacros(from: directory)
    }

    /// One file per id: an id already present is replaced in place rather than appended.
    public func add(_ macro: Macro) throws {
        try write(macro)
        if let index = macros.firstIndex(where: { $0.id == macro.id }) {
            macros[index] = macro
        } else {
            macros.append(macro)
        }
    }

    public func update(_ macro: Macro) throws {
        guard let index = macros.firstIndex(where: { $0.id == macro.id }) else {
            throw MacroStoreError.notFound(macro.id)
        }
        try write(macro)
        macros[index] = macro
    }

    public func delete(id: UUID) throws {
        let url = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        macros.removeAll { $0.id == id }
    }

    // MARK: - Private

    /// Self-healing load: a corrupt macro file is skipped, never crashes the rest.
    private static func loadMacros(from directory: URL) -> [Macro] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> Macro? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(Macro.self, from: data)
            }
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private func write(_ macro: Macro) throws {
        let data = try Self.encoder.encode(macro)
        try data.write(to: fileURL(for: macro.id), options: .atomic)
    }
}
