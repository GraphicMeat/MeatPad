import Foundation

public enum CommandInput: String, Codable, Sendable, CaseIterable {
    case none, selection, document
}

public enum CommandOutputMode: String, Codable, Sendable, CaseIterable {
    case replaceSelection, insertAtCaret, newNote, outputPanel
}

/// A user-defined shell command bound to editor context, persisted one JSON file per
/// command (see `CommandStore`).
public struct SavedCommand: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var script: String
    public var input: CommandInput
    public var output: CommandOutputMode
    /// "cmd+shift+r" style; nil = none. Parsing/validation is app-side.
    public var keyEquivalent: String?
    /// Empty = all languages.
    public var languageIDs: [String]

    public init(
        id: UUID = UUID(),
        name: String,
        script: String,
        input: CommandInput,
        output: CommandOutputMode,
        keyEquivalent: String? = nil,
        languageIDs: [String] = []
    ) {
        self.id = id
        self.name = name
        self.script = script
        self.input = input
        self.output = output
        self.keyEquivalent = keyEquivalent
        self.languageIDs = languageIDs
    }
}

public enum CommandStoreError: Error, Equatable {
    case notFound(UUID)
}

/// Owns the user's saved command collection: one `<uuid>.json` file per command under
/// `directory`. Same shape as `SnippetLibrary`, minus builtins/shadowing.
@MainActor
public final class CommandStore: ObservableObject {
    private let directory: URL

    @Published public private(set) var commands: [SavedCommand] = []

    private static let decoder = JSONDecoder()
    private static let encoder = JSONEncoder()

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        commands = Self.loadCommands(from: directory)
    }

    /// One file per id: an id already present is replaced in place rather than appended.
    public func add(_ command: SavedCommand) throws {
        try write(command)
        if let index = commands.firstIndex(where: { $0.id == command.id }) {
            commands[index] = command
        } else {
            commands.append(command)
        }
    }

    public func update(_ command: SavedCommand) throws {
        guard let index = commands.firstIndex(where: { $0.id == command.id }) else {
            throw CommandStoreError.notFound(command.id)
        }
        try write(command)
        commands[index] = command
    }

    public func delete(id: UUID) throws {
        let url = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        commands.removeAll { $0.id == id }
    }

    /// Commands scoped to `languageID` plus all-language commands. A nil `languageID`
    /// returns only all-language commands.
    public func commands(forLanguageID languageID: String?) -> [SavedCommand] {
        commands.filter { $0.languageIDs.isEmpty || (languageID != nil && $0.languageIDs.contains(languageID!)) }
    }

    // MARK: - Private

    /// Self-healing load: a corrupt command file is skipped, never crashes the rest.
    private static func loadCommands(from directory: URL) -> [SavedCommand] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> SavedCommand? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(SavedCommand.self, from: data)
            }
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private func write(_ command: SavedCommand) throws {
        let data = try Self.encoder.encode(command)
        try data.write(to: fileURL(for: command.id), options: .atomic)
    }
}
