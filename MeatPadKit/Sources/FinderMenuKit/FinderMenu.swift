import Foundation

/// A Finder menu row, free of AppKit so it can be tested; the extension turns it into
/// `NSMenuItem`s. Finder hands back only an item's tag on click, so the tag is the item's index
/// in `FinderMenuConfig.enabledActions`.
public enum FinderMenuEntry: Equatable, Sendable {
    case item(title: String, tag: Int)
    case submenu(title: String, items: [FinderMenuEntry])
}

public enum FinderMenu {
    public static let submenuTitle = "New File"

    /// Flat: "New Markdown File", "New Text File". Grouped: one "New File" submenu holding
    /// "Markdown", "Text". Nothing enabled: no entries at all (the extension then shows no menu).
    public static func entries(for config: FinderMenuConfig) -> [FinderMenuEntry] {
        let actions = config.enabledActions
        guard !actions.isEmpty else { return [] }
        if config.groupInSubmenu {
            let items = actions.enumerated().map { FinderMenuEntry.item(title: $1.title, tag: $0) }
            return [.submenu(title: submenuTitle, items: items)]
        }
        return actions.enumerated().map { .item(title: "New \($1.title) File", tag: $0) }
    }

    /// The clicked action, or `nil` for a tag that no longer matches (the config changed
    /// between building the menu and the click).
    public static func action(forTag tag: Int, in config: FinderMenuConfig) -> FinderNewFileAction? {
        let actions = config.enabledActions
        return actions.indices.contains(tag) ? actions[tag] : nil
    }

    /// Where the file goes: a single selected folder (right-click on a folder), otherwise the
    /// folder Finder says is targeted (the window's own folder for a blank-area click).
    public static func targetDirectory(targeted: URL?, selected: [URL], isDirectory: (URL) -> Bool) -> URL? {
        if selected.count == 1, let only = selected.first, isDirectory(only) { return only }
        return targeted
    }
}
