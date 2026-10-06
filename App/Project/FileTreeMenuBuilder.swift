import AppKit
import SwiftUI
import MeatPadKit

/// Titles and icons for the file-tree menu's actions. Titles are literal `String(localized:)`
/// calls, one per case, so the string catalog's extraction sees every one.
extension FileTreeAction {
    var title: String {
        switch self {
        case .newFile: String(localized: "New File…")
        case .newFolder: String(localized: "New Folder…")
        case .revealInFinder: String(localized: "Reveal in Finder")
        case .openInPreview: String(localized: "Open in Preview")
        case .openInTerminal: String(localized: "Open in Terminal")
        case .openInMeatPadTerminal: String(localized: "Open in MeatPad Terminal")
        case .findInFolder: String(localized: "Find in Folder…")
        case .cut: String(localized: "Cut")
        case .copy: String(localized: "Copy")
        case .paste: String(localized: "Paste")
        case .copyPath: String(localized: "Copy Path")
        case .copyRelativePath: String(localized: "Copy Relative Path")
        case .rename: String(localized: "Rename…")
        case .delete: String(localized: "Delete")
        }
    }

    var symbolName: String {
        switch self {
        case .newFile: "doc.badge.plus"
        case .newFolder: "folder.badge.plus"
        case .revealInFinder: "folder"
        case .openInPreview: "eye"
        case .openInTerminal: "terminal"
        case .openInMeatPadTerminal: "apple.terminal"
        case .findInFolder: "magnifyingglass"
        case .cut: "scissors"
        case .copy: "doc.on.doc"
        case .paste: "doc.on.clipboard"
        case .copyPath: "link"
        case .copyRelativePath: "arrow.turn.down.right"
        case .rename: "pencil"
        case .delete: "trash"
        }
    }
}

/// One menu row that runs a closure — the menu owns it, so the closure lives as long as the menu.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}

/// An `NSMenu` that says when it has closed — the file tree highlights the right-clicked row
/// until then. It is its own delegate, so nothing else has to keep it alive.
final class TrackingMenu: NSMenu, NSMenuDelegate {
    var onClose: (() -> Void)?

    override init(title: String) {
        super.init(title: title)
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    func menuDidClose(_ menu: NSMenu) { onClose?() }
}

/// Turns the Kit's menu model into a native `NSMenu`. Native, because SwiftUI's `.contextMenu`
/// has no second line under an item and Copy Path has to show what it copies.
@MainActor
enum FileTreeMenuBuilder {
    /// `isRoot`: the menu is for the project folder itself, so Find in Folder is "Find in Project".
    static func menu(for entries: [FileTreeMenuEntry], showIcons: Bool, isRoot: Bool = false,
                     perform: @escaping (FileTreeAction) -> Void) -> TrackingMenu {
        let menu = TrackingMenu(title: "")
        menu.autoenablesItems = false
        for entry in entries {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .item(let item):
                menu.addItem(menuItem(for: item, showIcons: showIcons, isRoot: isRoot, perform: perform))
            }
        }
        return menu
    }

    /// A plain item for menus outside the file tree (the tab menu) that share its look: icon when
    /// the user has icons on, optional second line.
    static func plainItem(title: String, symbol: String, subtitle: String? = nil, isEnabled: Bool = true,
                          showIcons: Bool, handler: @escaping () -> Void) -> NSMenuItem {
        let item = ActionMenuItem(title: title, handler: handler)
        item.isEnabled = isEnabled
        if showIcons { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        if let subtitle { applySubtitle(elided(subtitle), title: title, to: item) }
        return item
    }

    private static func menuItem(for item: FileTreeMenuItem, showIcons: Bool, isRoot: Bool,
                                 perform: @escaping (FileTreeAction) -> Void) -> NSMenuItem {
        let action = item.action
        let title = isRoot && action == .findInFolder ? String(localized: "Find in Project…") : action.title
        let menuItem = ActionMenuItem(title: title) { perform(action) }
        menuItem.isEnabled = item.isEnabled
        if showIcons {
            menuItem.image = NSImage(systemSymbolName: action.symbolName, accessibilityDescription: nil)
        }
        if let subtitle = item.subtitle {
            applySubtitle(elided(subtitle), title: title, to: menuItem)
        }
        if let shortcut = item.shortcut {
            menuItem.keyEquivalent = keyEquivalent(for: shortcut.key)
            menuItem.keyEquivalentModifierMask = modifierMask(for: shortcut.modifiers)
        }
        return menuItem
    }

    private static func applySubtitle(_ subtitle: String, title: String, to item: NSMenuItem) {
        if #available(macOS 14.4, *) {
            item.subtitle = subtitle
        } else {
            let text = NSMutableAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
            text.append(NSAttributedString(string: "\n" + subtitle, attributes: [
                .font: NSFont.menuFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            item.attributedTitle = text
        }
    }

    /// A deep path would otherwise stretch the menu across the screen, so the middle is elided.
    static func elided(_ text: String, limit: Int = 64) -> String {
        guard text.count > limit else { return text }
        let head = (limit - 1) / 3
        let tail = limit - 1 - head
        return String(text.prefix(head)) + "…" + String(text.suffix(tail))
    }

    /// The Kit stores special keys as glyphs; AppKit wants the control character.
    static func keyEquivalent(for key: String) -> String {
        switch key {
        case "↩": "\r"
        case "⌫": String(UnicodeScalar(UInt8(NSBackspaceCharacter)))
        case "⌦": String(UnicodeScalar(UInt16(NSDeleteFunctionKey))!)
        case "⇥": "\t"
        case "⎋": "\u{1B}"
        case "␣": " "
        default: key
        }
    }

    static func modifierMask(for modifiers: FileTreeShortcut.Modifiers) -> NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if modifiers.contains(.control) { mask.insert(.control) }
        if modifiers.contains(.option) { mask.insert(.option) }
        if modifiers.contains(.shift) { mask.insert(.shift) }
        if modifiers.contains(.command) { mask.insert(.command) }
        return mask
    }
}

/// Puts a native context menu on a SwiftUI row. The view sits over the row but only answers
/// hit tests for a right-click (or control-click), so every other click — selecting, opening a
/// file — still reaches the row beneath. It is not an accessibility element: the row's own text
/// stays the thing UI tests and VoiceOver see.
struct RowContextMenu: NSViewRepresentable {
    let makeMenu: () -> NSMenu?
    /// A middle-button click (a tab closes on it, as in VS Code). Nil = middle-clicks pass through.
    var onMiddleClick: (() -> Void)?
    /// Control-click. When set it replaces the system's control-click-as-right-click, so the
    /// menu opens on a real right-click only (the tab bar: control-click closes the tab).
    var onControlClick: (() -> Void)?

    func makeNSView(context: Context) -> MenuHostView {
        let view = MenuHostView()
        view.makeMenu = makeMenu
        view.onMiddleClick = onMiddleClick
        view.onControlClick = onControlClick
        return view
    }

    func updateNSView(_ view: MenuHostView, context: Context) {
        view.makeMenu = makeMenu
        view.onMiddleClick = onMiddleClick
        view.onControlClick = onControlClick
    }

    final class MenuHostView: NSView {
        var makeMenu: (() -> NSMenu?)?
        var onMiddleClick: (() -> Void)?
        var onControlClick: (() -> Void)?

        private func isControlClick(_ event: NSEvent) -> Bool {
            event.type == .leftMouseDown && event.modifierFlags.contains(.control)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let isMenuClick = event.type == .rightMouseDown || (isControlClick(event) && onControlClick == nil)
            let isHandledControlClick = isControlClick(event) && onControlClick != nil
            let isMiddleClick = onMiddleClick != nil
                && (event.type == .otherMouseDown || event.type == .otherMouseUp) && event.buttonNumber == 2
            return (isMenuClick || isHandledControlClick || isMiddleClick) ? super.hitTest(point) : nil
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            if isControlClick(event) && onControlClick != nil { return nil }
            return makeMenu?()
        }

        override func mouseDown(with event: NSEvent) {
            if isControlClick(event), let onControlClick { onControlClick() } else { super.mouseDown(with: event) }
        }

        override func otherMouseDown(with event: NSEvent) {
            if event.buttonNumber != 2 { super.otherMouseDown(with: event) }
        }

        override func otherMouseUp(with event: NSEvent) {
            if event.buttonNumber == 2 { onMiddleClick?() } else { super.otherMouseUp(with: event) }
        }

        override func isAccessibilityElement() -> Bool { false }
    }
}
