import Foundation

/// A keyboard shortcut as the file-tree context menu shows it ("⌥⌘R"). Kept free of AppKit so
/// the menu model and the settings pane can be tested; the app turns it into an
/// `NSMenuItem` key equivalent.
public struct FileTreeShortcut: Equatable, Sendable {
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    /// One character, lowercase — or a glyph for a special key (↩ ⌫ ⌦ ⇥ ⎋ ␣).
    public let key: String
    public let modifiers: Modifiers

    public init(key: String, modifiers: Modifiers) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    private static let glyphs: [(Modifiers, Character)] = [
        (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
    ]

    /// Modifiers in the Mac menu order (⌃⌥⇧⌘), then the key uppercased.
    public var display: String {
        Self.glyphs.filter { modifiers.contains($0.0) }.map { String($0.1) }.joined() + key.uppercased()
    }

    /// Inverse of `display`. Modifier order is free; exactly one key character must follow.
    public init?(display: String) {
        var modifiers: Modifiers = []
        var rest: [Character] = []
        for character in display {
            if let match = Self.glyphs.first(where: { $0.1 == character }) {
                modifiers.insert(match.0)
            } else {
                rest.append(character)
            }
        }
        guard rest.count == 1 else { return nil }
        self.init(key: String(rest[0]), modifiers: modifiers)
    }
}

/// Everything the sidebar's right-click menu can offer — the VS Code explorer set. Declaration
/// order is menu order.
public enum FileTreeAction: String, CaseIterable, Codable, Sendable {
    case newFile, newFolder
    case revealInFinder, openInPreview, openInTerminal, openInMeatPadTerminal
    case findInFolder
    case cut, copy, paste
    case copyPath, copyRelativePath
    case rename, delete

    /// Items in the same group sit together; a separator goes between groups.
    var group: Int {
        switch self {
        case .newFile, .newFolder: 0
        case .revealInFinder, .openInPreview, .openInTerminal, .openInMeatPadTerminal: 1
        case .findInFolder: 2
        case .cut, .copy, .paste: 3
        case .copyPath, .copyRelativePath: 4
        case .rename, .delete: 5
        }
    }

    /// VS Code's key for the action, as shown in its menu.
    public var defaultShortcut: FileTreeShortcut? {
        switch self {
        case .revealInFinder: FileTreeShortcut(key: "r", modifiers: [.option, .command])
        case .findInFolder: FileTreeShortcut(key: "f", modifiers: [.option, .shift])
        case .cut: FileTreeShortcut(key: "x", modifiers: .command)
        case .copy: FileTreeShortcut(key: "c", modifiers: .command)
        case .paste: FileTreeShortcut(key: "v", modifiers: .command)
        case .copyPath: FileTreeShortcut(key: "c", modifiers: [.option, .command])
        case .copyRelativePath: FileTreeShortcut(key: "c", modifiers: [.option, .shift, .command])
        case .rename: FileTreeShortcut(key: "↩", modifiers: [])
        case .delete: FileTreeShortcut(key: "⌫", modifiers: .command)
        case .newFile, .newFolder, .openInPreview, .openInTerminal, .openInMeatPadTerminal: nil
        }
    }
}

/// The user's menu choices: which items show, which key each displays, and whether rows carry
/// icons. Persisted as JSON in UserDefaults.
public struct FileTreeMenuConfig: Codable, Equatable, Sendable {
    public var showIcons: Bool
    /// `FileTreeAction.rawValue`s the user hid. Raw strings, not the enum, so a name from a
    /// newer or older build never breaks decoding.
    public var hidden: Set<String>
    /// Action raw value → shortcut display text; `""` means "no shortcut", overriding a default.
    public var shortcutOverrides: [String: String]

    public init(showIcons: Bool = true, hidden: Set<String> = [], shortcutOverrides: [String: String] = [:]) {
        self.showIcons = showIcons
        self.hidden = hidden
        self.shortcutOverrides = shortcutOverrides
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showIcons = try c.decodeIfPresent(Bool.self, forKey: .showIcons) ?? true
        hidden = try c.decodeIfPresent(Set<String>.self, forKey: .hidden) ?? []
        shortcutOverrides = try c.decodeIfPresent([String: String].self, forKey: .shortcutOverrides) ?? [:]
    }

    public func isVisible(_ action: FileTreeAction) -> Bool { !hidden.contains(action.rawValue) }

    public mutating func setVisible(_ visible: Bool, for action: FileTreeAction) {
        if visible { hidden.remove(action.rawValue) } else { hidden.insert(action.rawValue) }
    }

    public func shortcut(for action: FileTreeAction) -> FileTreeShortcut? {
        guard let override = shortcutOverrides[action.rawValue] else { return action.defaultShortcut }
        return FileTreeShortcut(display: override)
    }

    /// `nil` clears the shortcut (even a default one). Setting the default back drops the override.
    public mutating func setShortcut(_ shortcut: FileTreeShortcut?, for action: FileTreeAction) {
        if shortcut == action.defaultShortcut {
            shortcutOverrides[action.rawValue] = nil
        } else {
            shortcutOverrides[action.rawValue] = shortcut?.display ?? ""
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Missing or unreadable data is the defaults, never an error — a bad preference must not
    /// take the menu away.
    public static func decode(_ data: Data?) -> FileTreeMenuConfig {
        guard let data, let config = try? JSONDecoder().decode(FileTreeMenuConfig.self, from: data) else {
            return FileTreeMenuConfig()
        }
        return config
    }
}

/// What the menu is being built for.
public struct FileTreeMenuContext: Sendable {
    public let target: URL
    public let isDirectory: Bool
    public let root: URL
    public let clipboardHasFiles: Bool

    public init(target: URL, isDirectory: Bool, root: URL, clipboardHasFiles: Bool) {
        self.target = target
        self.isDirectory = isDirectory
        self.root = root
        self.clipboardHasFiles = clipboardHasFiles
    }

    /// The menu is for the project folder itself — the tree's top row.
    public var isRoot: Bool { target.standardizedFileURL.path == root.standardizedFileURL.path }
}

public struct FileTreeMenuItem: Equatable, Sendable {
    public let action: FileTreeAction
    public let isEnabled: Bool
    /// A smaller second line: for the two copy-path items, exactly what they will copy.
    public let subtitle: String?
    public let shortcut: FileTreeShortcut?
}

public enum FileTreeMenuEntry: Equatable, Sendable {
    case item(FileTreeMenuItem)
    case separator
}

public enum FileTreeMenu {
    /// The visible items for `context`, grouped with separators. A group with nothing visible
    /// leaves no separator behind, and the menu never starts or ends on one.
    public static func entries(for context: FileTreeMenuContext, config: FileTreeMenuConfig) -> [FileTreeMenuEntry] {
        var entries: [FileTreeMenuEntry] = []
        var lastGroup: Int?
        for action in FileTreeAction.allCases where config.isVisible(action) {
            if action == .openInPreview && context.isDirectory { continue }
            if context.isRoot && rootOmits.contains(action) { continue }
            if let lastGroup, lastGroup != action.group { entries.append(.separator) }
            lastGroup = action.group
            entries.append(.item(FileTreeMenuItem(
                action: action,
                isEnabled: action != .paste || context.clipboardHasFiles,
                subtitle: subtitle(for: action, context: context),
                shortcut: config.shortcut(for: action)
            )))
        }
        return entries
    }

    /// Nothing on the project folder itself can be cut, copied, renamed or deleted, and its
    /// relative path would be empty.
    private static let rootOmits: Set<FileTreeAction> = [.cut, .copy, .rename, .delete, .copyRelativePath]

    private static func subtitle(for action: FileTreeAction, context: FileTreeMenuContext) -> String? {
        switch action {
        case .copyPath: context.target.path
        case .copyRelativePath: FileTreePaths.relativePath(of: context.target, in: context.root)
        default: nil
        }
    }
}
