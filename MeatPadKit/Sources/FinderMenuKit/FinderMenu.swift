import Foundation

/// A Finder menu row, free of AppKit so it can be tested; the extension turns it into
/// `NSMenuItem`s. Finder hands back only an item's tag on click, so the tag is the item's index
/// in `FinderMenuConfig.enabledActions`, offset for the items menu (see `FinderMenu.Kind`).
public enum FinderMenuEntry: Equatable, Sendable {
    case item(title: String, tag: Int)
    case submenu(title: String, items: [FinderMenuEntry])
}

public enum FinderMenu {
    public static let submenuTitle = "New File"

    /// Which right-click the menu answers: blank space in a window (`container`) or one or
    /// more items (`items`). Finder does not tell the click handler, so the kind rides in the
    /// item's tag: container tags are the plain index, items tags are offset by
    /// `itemsTagOffset`.
    public enum Kind: Int, Equatable, Sendable { case container, items }

    public static let itemsTagOffset = 1 << 16

    /// Flat: "New Markdown File", "New Text File". Grouped: one "New File" submenu holding
    /// "Markdown", "Text". Nothing enabled: no entries at all (the extension then shows no menu).
    public static func entries(for config: FinderMenuConfig, kind: Kind = .container) -> [FinderMenuEntry] {
        let actions = config.enabledActions
        guard !actions.isEmpty else { return [] }
        let base = kind == .items ? itemsTagOffset : 0
        if config.groupInSubmenu {
            let items = actions.enumerated().map { FinderMenuEntry.item(title: $1.title, tag: base + $0) }
            return [.submenu(title: submenuTitle, items: items)]
        }
        return actions.enumerated().map { .item(title: "New \($1.title) File", tag: base + $0) }
    }

    /// The menu kind a tag was built for; `nil` for a tag outside both ranges.
    public static func kind(forTag tag: Int) -> Kind? {
        switch tag {
        case 0..<itemsTagOffset: .container
        case itemsTagOffset..<(2 * itemsTagOffset): .items
        default: nil
        }
    }

    /// The clicked action, or `nil` for a tag that no longer matches (the config changed
    /// between building the menu and the click).
    public static func action(forTag tag: Int, in config: FinderMenuConfig) -> FinderNewFileAction? {
        guard kind(forTag: tag) != nil else { return nil }
        let index = tag % itemsTagOffset
        let actions = config.enabledActions
        return actions.indices.contains(index) ? actions[index] : nil
    }

    /// Where the file goes: a single selected folder (right-click on a folder), otherwise the
    /// folder Finder says is targeted (the window's own folder for a blank-area click).
    public static func targetDirectory(targeted: URL?, selected: [URL], isDirectory: (URL) -> Bool) -> URL? {
        if selected.count == 1, let only = selected.first, isDirectory(only) { return only }
        return targeted
    }

    /// Where the file goes for a click in a menu of `kind`: a blank-area menu always targets
    /// the window's own folder, even with a folder still selected in it; an items menu applies
    /// the one-selected-folder rule above.
    public static func targetDirectory(kind: Kind, targeted: URL?, selected: [URL], isDirectory: (URL) -> Bool) -> URL? {
        switch kind {
        case .container: targeted
        case .items: targetDirectory(targeted: targeted, selected: selected, isDirectory: isDirectory)
        }
    }
}
