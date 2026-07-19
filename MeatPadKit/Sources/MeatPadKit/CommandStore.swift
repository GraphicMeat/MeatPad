import Foundation

public enum CommandInput: String, Codable, Sendable, CaseIterable {
    case none, selection, document
}

public enum CommandOutputMode: String, Codable, Sendable, CaseIterable {
    case replaceSelection, insertAtCaret, newNote, outputPanel
}

/// Where a command came from, and therefore whether it's trusted by default. A
/// hand-authored `Codable` (rather than the enum-with-associated-values synthesis,
/// which nests everything under a payload key) so the JSON stays a flat, readable
/// tagged object: `{"type":"user"}` or `{"type":"imported","bundleName":"X.tmbundle","date":...}`.
public enum CommandOrigin: Equatable, Sendable {
    case user
    case imported(bundleName: String, date: Date)
}

extension CommandOrigin: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, bundleName, date
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "user":
            self = .user
        case "imported":
            self = .imported(
                bundleName: try container.decode(String.self, forKey: .bundleName),
                date: try container.decode(Date.self, forKey: .date)
            )
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown CommandOrigin type: \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .user:
            try container.encode("user", forKey: .type)
        case .imported(let bundleName, let date):
            try container.encode("imported", forKey: .type)
            try container.encode(bundleName, forKey: .bundleName)
            try container.encode(date, forKey: .date)
        }
    }
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
    /// Provenance: `.user` (hand-authored) or `.imported` (from a bundle). Drives the
    /// `trusted` default at creation time; not re-derived afterward.
    public var origin: CommandOrigin
    /// Whether this command may run without a confirmation gate. Commands saved before
    /// this field existed are grandfathered as trusted (see the `decodeIfPresent`
    /// default in `init(from:)`) — only newly imported commands start untrusted.
    public var trusted: Bool
    /// Overrides `CommandRunner.run`'s default 30s timeout when set; nil defers to it.
    public var timeoutSeconds: Double?
    /// true → `TMEnvironment.build` passes only `TM_*` vars plus a small allowlist
    /// instead of the full parent process environment. See `TMEnvironment.restrictedAllowlist`.
    public var restrictedEnvironment: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        script: String,
        input: CommandInput,
        output: CommandOutputMode,
        keyEquivalent: String? = nil,
        languageIDs: [String] = [],
        origin: CommandOrigin = .user,
        trusted: Bool = true,
        timeoutSeconds: Double? = nil,
        restrictedEnvironment: Bool = false
    ) {
        self.id = id
        self.name = name
        self.script = script
        self.input = input
        self.output = output
        self.keyEquivalent = keyEquivalent
        self.languageIDs = languageIDs
        self.origin = origin
        self.trusted = trusted
        self.timeoutSeconds = timeoutSeconds
        self.restrictedEnvironment = restrictedEnvironment
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, script, input, output, keyEquivalent, languageIDs
        case origin, trusted, timeoutSeconds, restrictedEnvironment
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        script = try container.decode(String.self, forKey: .script)
        input = try container.decode(CommandInput.self, forKey: .input)
        output = try container.decode(CommandOutputMode.self, forKey: .output)
        keyEquivalent = try container.decodeIfPresent(String.self, forKey: .keyEquivalent)
        languageIDs = try container.decode([String].self, forKey: .languageIDs)
        // Trust-model fields (0.8): decodeIfPresent + default so command JSONs written
        // before these fields existed load unchanged instead of failing to decode,
        // grandfathered as trusted/.user per the migration-safety constraint.
        origin = try container.decodeIfPresent(CommandOrigin.self, forKey: .origin) ?? .user
        trusted = try container.decodeIfPresent(Bool.self, forKey: .trusted) ?? true
        timeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds)
        restrictedEnvironment = try container.decodeIfPresent(Bool.self, forKey: .restrictedEnvironment) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(script, forKey: .script)
        try container.encode(input, forKey: .input)
        try container.encode(output, forKey: .output)
        try container.encodeIfPresent(keyEquivalent, forKey: .keyEquivalent)
        try container.encode(languageIDs, forKey: .languageIDs)
        try container.encode(origin, forKey: .origin)
        try container.encode(trusted, forKey: .trusted)
        try container.encodeIfPresent(timeoutSeconds, forKey: .timeoutSeconds)
        try container.encode(restrictedEnvironment, forKey: .restrictedEnvironment)
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
