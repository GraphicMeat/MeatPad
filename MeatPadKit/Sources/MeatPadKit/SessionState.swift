import Foundation

/// Snapshot of which windows were open, so relaunch can put them back — the app's core
/// promise ("every window must come back after quit"). Read once at launch; written
/// debounced on every change and immediately on app termination.
public struct SessionState: Codable, Equatable, Sendable {
    public var openNoteIDs: [UUID]
    public var browserOpen: Bool

    public init(openNoteIDs: [UUID], browserOpen: Bool) {
        self.openNoteIDs = openNoteIDs
        self.browserOpen = browserOpen
    }

    /// nil on a missing or corrupt file — session restore is a nice-to-have, never a
    /// launch blocker. Never throws.
    public static func load(from url: URL) -> SessionState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionState.self, from: data)
    }

    public func save(to url: URL) throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }
}
