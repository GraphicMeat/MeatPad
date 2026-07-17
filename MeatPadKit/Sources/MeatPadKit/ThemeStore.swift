import Foundation

public enum ThemeStoreError: Error, Equatable {
    case builtinReadOnly(String)
    case notFound(String)
}

/// Owns the user's custom theme collection: one `<id>.json` file per theme under
/// `directory`. `BuiltinThemes.all` is always available and read-only; `id` is a
/// String (builtins use fixed ids like "meat-dark", user themes "user-<uuid>").
@MainActor
public final class ThemeStore: ObservableObject {
    private let directory: URL

    @Published public private(set) var userThemes: [Theme] = []

    private static let decoder = JSONDecoder()
    private static let encoder = JSONEncoder()

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        userThemes = Self.loadUserThemes(from: directory)
    }

    public var allThemes: [Theme] {
        BuiltinThemes.all + userThemes
    }

    public func theme(id: String) -> Theme? {
        allThemes.first { $0.id == id }
    }

    public func isBuiltin(id: String) -> Bool {
        BuiltinThemes.all.contains { $0.id == id }
    }

    /// Copies any theme (builtin or user) into a fresh, persisted user theme.
    public func duplicate(id: String) throws -> Theme {
        guard let original = theme(id: id) else { throw ThemeStoreError.notFound(id) }
        var copy = original
        copy.id = "user-" + UUID().uuidString
        copy.name = "\(original.name) Copy"
        try save(copy)
        return copy
    }

    public func save(_ theme: Theme) throws {
        guard !isBuiltin(id: theme.id) else {
            throw ThemeStoreError.builtinReadOnly(theme.id)
        }
        try write(theme)
        if let index = userThemes.firstIndex(where: { $0.id == theme.id }) {
            userThemes[index] = theme
        } else {
            userThemes.append(theme)
        }
    }

    public func delete(id: String) throws {
        guard !isBuiltin(id: id) else {
            throw ThemeStoreError.builtinReadOnly(id)
        }
        let url = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        userThemes.removeAll { $0.id == id }
    }

    // MARK: - Private

    /// Self-healing load: a corrupt theme file is skipped, never crashes the rest.
    private static func loadUserThemes(from directory: URL) -> [Theme] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> Theme? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(Theme.self, from: data)
            }
    }

    private func fileURL(for id: String) -> URL {
        directory.appendingPathComponent(id).appendingPathExtension("json")
    }

    private func write(_ theme: Theme) throws {
        let data = try Self.encoder.encode(theme)
        try data.write(to: fileURL(for: theme.id), options: .atomic)
    }
}
