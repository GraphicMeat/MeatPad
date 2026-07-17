import Foundation

public enum SnippetLibraryError: Error, Equatable {
    case notFound(UUID)
}

/// A TextMate-style snippet: a trigger word that expands to `body` via `SnippetParser`.
/// `languageIDs` scopes the snippet to specific `Language.id` values; an empty array
/// means "all languages".
public struct Snippet: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var trigger: String
    public var languageIDs: [String]
    public var body: String

    public init(id: UUID = UUID(), name: String, trigger: String, languageIDs: [String], body: String) {
        self.id = id
        self.name = name
        self.trigger = trigger
        self.languageIDs = languageIDs
        self.body = body
    }
}

/// Owns the user's custom snippet collection: one `<uuid>.json` file per snippet under
/// `userDirectory`. `BuiltinSnippets.all` is always available; a user snippet with the
/// same trigger and an overlapping language scope shadows the matching builtin.
@MainActor
public final class SnippetLibrary: ObservableObject {
    private let userDirectory: URL

    @Published public private(set) var userSnippets: [Snippet] = []

    private static let decoder = JSONDecoder()
    private static let encoder = JSONEncoder()

    public init(userDirectory: URL) {
        self.userDirectory = userDirectory
        try? FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        userSnippets = Self.loadUserSnippets(from: userDirectory)
    }

    /// Builtins plus user snippets, minus any builtin fully superseded by a user
    /// snippet that shares its trigger and covers its ENTIRE language scope. A user
    /// snippet that only covers part of a multi-language builtin's scope leaves the
    /// builtin visible here — `snippets(forLanguageID:)` handles the per-language split.
    public var all: [Snippet] {
        let visibleBuiltins = BuiltinSnippets.all.filter { builtin in
            !userSnippets.contains { user in
                user.trigger == builtin.trigger && Self.scopeFullyCovers(user.languageIDs, builtin.languageIDs)
            }
        }
        return visibleBuiltins + userSnippets
    }

    /// Resolution order: exact-language user > exact-language builtin > all-language
    /// user > all-language builtin. A nil `languageID` matches only all-language
    /// snippets (the exact-language tiers are skipped).
    public func snippet(trigger: String, languageID: String?) -> Snippet? {
        let userMatches = userSnippets.filter { $0.trigger == trigger }
        let builtinMatches = BuiltinSnippets.all.filter { $0.trigger == trigger }

        if let languageID {
            if let exactUser = userMatches.first(where: { $0.languageIDs.contains(languageID) }) {
                return exactUser
            }
            if let exactBuiltin = builtinMatches.first(where: { $0.languageIDs.contains(languageID) }) {
                return exactBuiltin
            }
        }
        if let allLanguageUser = userMatches.first(where: { $0.languageIDs.isEmpty }) {
            return allLanguageUser
        }
        if let allLanguageBuiltin = builtinMatches.first(where: { $0.languageIDs.isEmpty }) {
            return allLanguageBuiltin
        }
        return nil
    }

    /// For the Insert Snippet menu: snippets scoped to `languageID` plus all-language
    /// snippets, name-sorted. A nil `languageID` returns only all-language snippets.
    /// Resolved per-trigger via `snippet(trigger:languageID:)` so a narrow user override
    /// only shadows the builtin for the languages it actually covers.
    public func snippets(forLanguageID languageID: String?) -> [Snippet] {
        let applicable = (userSnippets + BuiltinSnippets.all).filter {
            $0.languageIDs.isEmpty || (languageID != nil && $0.languageIDs.contains(languageID!))
        }
        let triggers = Set(applicable.map(\.trigger))
        return triggers
            .compactMap { snippet(trigger: $0, languageID: languageID) }
            .sorted { $0.name < $1.name }
    }

    /// One file per id: an id already present is replaced in place rather than appended.
    public func add(_ snippet: Snippet) throws {
        try write(snippet)
        if let index = userSnippets.firstIndex(where: { $0.id == snippet.id }) {
            userSnippets[index] = snippet
        } else {
            userSnippets.append(snippet)
        }
    }

    public func update(_ snippet: Snippet) throws {
        guard let index = userSnippets.firstIndex(where: { $0.id == snippet.id }) else {
            throw SnippetLibraryError.notFound(snippet.id)
        }
        try write(snippet)
        userSnippets[index] = snippet
    }

    public func delete(id: UUID) throws {
        let url = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        userSnippets.removeAll { $0.id == id }
    }

    // MARK: - Private

    /// Does `user`'s scope fully cover `builtin`'s scope (so the builtin can be dropped
    /// entirely, not just for some languages)? Empty means "all languages": a builtin
    /// with an empty scope can only be fully covered by an equally universal user
    /// snippet; a finite user scope can never cover the entire language universe.
    private static func scopeFullyCovers(_ user: [String], _ builtin: [String]) -> Bool {
        if builtin.isEmpty { return user.isEmpty }
        return user.isEmpty || Set(builtin).isSubset(of: Set(user))
    }

    /// Self-healing load: a corrupt snippet file is skipped, never crashes the rest.
    private static func loadUserSnippets(from directory: URL) -> [Snippet] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> Snippet? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(Snippet.self, from: data)
            }
    }

    private func fileURL(for id: UUID) -> URL {
        userDirectory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private func write(_ snippet: Snippet) throws {
        let data = try Self.encoder.encode(snippet)
        try data.write(to: fileURL(for: snippet.id), options: .atomic)
    }
}
