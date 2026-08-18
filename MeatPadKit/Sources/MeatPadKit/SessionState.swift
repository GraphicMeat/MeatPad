import Foundation

/// One open project window: its root folder, which files are open as tabs, and which
/// tab was selected.
public struct ProjectSession: Codable, Equatable, Sendable {
    public var root: String
    public var openTabs: [String]
    public var selectedTab: String?

    public init(root: String, openTabs: [String], selectedTab: String?) {
        self.root = root
        self.openTabs = openTabs
        self.selectedTab = selectedTab
    }
}

/// Snapshot of which windows were open, so relaunch can put them back — the app's core
/// promise ("every window must come back after quit"). Read once at launch; written
/// debounced on every change and immediately on app termination.
public struct SessionState: Codable, Equatable, Sendable {
    public var openNoteIDs: [UUID]
    public var browserOpen: Bool
    public var openProjects: [ProjectSession]
    public var boardsOpen: Bool

    public init(openNoteIDs: [UUID], browserOpen: Bool, openProjects: [ProjectSession] = [], boardsOpen: Bool = false) {
        self.openNoteIDs = openNoteIDs
        self.browserOpen = browserOpen
        self.openProjects = openProjects
        self.boardsOpen = boardsOpen
    }

    private enum CodingKeys: String, CodingKey {
        case openNoteIDs, browserOpen, openProjects, boardsOpen
    }

    // Custom decode: synthesized Codable doesn't fall back to a property's default value
    // for a missing key, so older session.json files (written before openProjects, and
    // before boardsOpen) would otherwise fail to decode entirely. `encode(to:)` stays synthesized.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        openNoteIDs = try container.decode([UUID].self, forKey: .openNoteIDs)
        browserOpen = try container.decode(Bool.self, forKey: .browserOpen)
        openProjects = try container.decodeIfPresent([ProjectSession].self, forKey: .openProjects) ?? []
        boardsOpen = try container.decodeIfPresent(Bool.self, forKey: .boardsOpen) ?? false
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
