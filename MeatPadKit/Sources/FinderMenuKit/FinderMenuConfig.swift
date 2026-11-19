import Foundation

/// One "New … File" item in Finder's right-click menu.
public struct FinderNewFileAction: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// What the menu says: "New \(title) File" (or just the title inside the submenu).
    public var title: String
    /// As the user typed it; `FinderMenuConfig.sanitizedExtension` cleans it on use.
    public var fileExtension: String
    public var isEnabled: Bool

    public init(id: UUID = UUID(), title: String, fileExtension: String, isEnabled: Bool = true) {
        self.id = id
        self.title = title
        self.fileExtension = fileExtension
        self.isEnabled = isEnabled
    }

    /// Tolerant: a missing key takes its default rather than failing the whole menu.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        fileExtension = (try? c.decodeIfPresent(String.self, forKey: .fileExtension)) ?? ""
        isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? true
    }
}

/// The Finder menu's settings, shared by the app (which edits them and acts on clicks) and the
/// Finder Sync extension (which only reads them to build the menu). Stored as JSON *text*
/// under `finder.menu` in the app's defaults domain, like `fileTree.menu`.
public struct FinderMenuConfig: Codable, Equatable, Sendable {

    /// What the app does once the file exists.
    public enum AfterCreate: String, Codable, CaseIterable, Sendable {
        case openInMeatPad, showInFinder
    }

    public static let defaultsKey = "finder.menu"

    /// Fixed ids, so "the defaults" compare equal across launches and resets.
    public static let defaultActions: [FinderNewFileAction] = [
        FinderNewFileAction(
            id: UUID(uuidString: "6D2B7E1A-3C5F-4B8E-9A1D-0F4E2C7B9A01")!,
            title: "Markdown", fileExtension: "md"
        ),
        FinderNewFileAction(
            id: UUID(uuidString: "6D2B7E1A-3C5F-4B8E-9A1D-0F4E2C7B9A02")!,
            title: "Text", fileExtension: "txt"
        ),
    ]

    public var actions: [FinderNewFileAction]
    public var groupInSubmenu: Bool
    public var afterCreate: AfterCreate

    public init(
        actions: [FinderNewFileAction] = defaultActions,
        groupInSubmenu: Bool = false,
        afterCreate: AfterCreate = .openInMeatPad
    ) {
        self.actions = actions
        self.groupInSubmenu = groupInSubmenu
        self.afterCreate = afterCreate
    }

    /// Every key is optional. `afterCreate` is read as a raw string so a value from a newer
    /// build falls back to the default instead of throwing the whole config away.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        actions = try c.decodeIfPresent([FinderNewFileAction].self, forKey: .actions) ?? Self.defaultActions
        groupInSubmenu = (try? c.decodeIfPresent(Bool.self, forKey: .groupInSubmenu)) ?? false
        let raw: String? = try? c.decodeIfPresent(String.self, forKey: .afterCreate)
        afterCreate = raw.flatMap(AfterCreate.init(rawValue:)) ?? .openInMeatPad
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Missing or unreadable data is the defaults, never an error: this runs inside Finder's
    /// menu callback, where a bad preference must not take the menu away.
    public static func decode(_ data: Data?) -> FinderMenuConfig {
        guard let data, let config = try? JSONDecoder().decode(FinderMenuConfig.self, from: data) else {
            return FinderMenuConfig()
        }
        return config
    }

    /// Trimmed, leading dots dropped, then 1–16 of `A–Z a–z 0–9 _ + -`; anything else is `nil`.
    /// Case is kept. Nothing that could name a path ("/", "..") gets through.
    public static func sanitizedExtension(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = String(trimmed.drop { $0 == "." })
        guard (1...16).contains(candidate.count) else { return nil }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-")
        guard candidate.allSatisfy({ allowed.contains($0) }) else { return nil }
        return candidate
    }

    /// What the menu offers, in order: enabled, with a title, and an extension that sanitises —
    /// returned trimmed and sanitised.
    public var enabledActions: [FinderNewFileAction] {
        actions.compactMap { action in
            guard action.isEnabled else { return nil }
            let title = action.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, let ext = Self.sanitizedExtension(action.fileExtension) else { return nil }
            var clean = action
            clean.title = title
            clean.fileExtension = ext
            return clean
        }
    }
}
