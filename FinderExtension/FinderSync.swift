import AppKit
import FinderMenuKit
import FinderSync
import os

/// MeatPad's Finder Sync extension: adds "New … File" items to Finder's right-click menu.
///
/// It is deliberately a dumb menu. It runs sandboxed inside Finder's orbit and cannot write
/// outside its container, so a click only opens `meatpad://new-file?dir=…&ext=…`; the
/// (unsandboxed) app creates the file. Finder forwards an item's title, tag, image and
/// action across the process boundary but not its `representedObject`, so items are told
/// apart by `tag`: the index into `FinderMenuConfig.enabledActions`, offset by
/// `FinderMenu.itemsTagOffset` for the items menu, so the click handler (which Finder does not
/// tell which menu it came from) knows whether the one-selected-folder rule applies.
///
/// `menu(for:)` runs inside Finder's menu tracking: it must never throw, block or crash. The
/// config is read fresh each time (a Settings change applies to the next right-click) and a
/// bad or missing value is simply the defaults.
///
/// Privacy: nothing here logs a file path, a URL or a folder name. The `finder.menu` read is
/// logged once, at init (scripts/finder-read-check.sh waits for that line).
final class FinderSync: FIFinderSync {

    private let log = Logger(subsystem: "com.thecoldzero.MeatPad.FinderSync", category: "finder")

    override init() {
        super.init()
        var roots = [URL(fileURLWithPath: "/")]
        roots += FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]
        ) ?? []
        FIFinderSyncController.default().directoryURLs = Set(roots)
        log.notice("init: watching \(roots.count, privacy: .public) root(s)")
        _ = loadConfig(logRead: true)
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        // The kind travels in each item's tag: the click handler is not told which menu it
        // came from, and a blank-area click must ignore whatever is still selected.
        let kind: FinderMenu.Kind
        switch menuKind {
        case .contextualMenuForContainer: kind = .container
        case .contextualMenuForItems: kind = .items
        default: return nil
        }
        let entries = FinderMenu.entries(for: loadConfig(), kind: kind)
        log.notice("menu(for: \(menuKind.rawValue, privacy: .public)) -> \(Self.itemCount(entries), privacy: .public) item(s)")
        guard !entries.isEmpty else { return nil }

        let menu = NSMenu(title: "")
        for entry in entries { menu.addItem(makeItem(entry)) }
        return menu
    }

    private func makeItem(_ entry: FinderMenuEntry) -> NSMenuItem {
        switch entry {
        case let .item(title, tag):
            let item = NSMenuItem(title: title, action: #selector(newFile(_:)), keyEquivalent: "")
            item.tag = tag
            item.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)
            return item
        case let .submenu(title, items):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)
            let submenu = NSMenu(title: title)
            for child in items { submenu.addItem(makeItem(child)) }
            item.submenu = submenu
            return item
        }
    }

    private static func itemCount(_ entries: [FinderMenuEntry]) -> Int {
        entries.reduce(0) { count, entry in
            switch entry {
            case .item: count + 1
            case let .submenu(_, items): count + itemCount(items)
            }
        }
    }

    @objc private func newFile(_ sender: NSMenuItem) {
        let config = loadConfig()
        let controller = FIFinderSyncController.default()
        let selected = controller.selectedItemURLs() ?? []
        guard let kind = FinderMenu.kind(forTag: sender.tag),
              let action = FinderMenu.action(forTag: sender.tag, in: config),
              let directory = FinderMenu.targetDirectory(
                  kind: kind, targeted: controller.targetedURL(), selected: selected, isDirectory: Self.isDirectory
              ),
              let request = NewFileRequest(directory: directory, fileExtension: action.fileExtension)
        else {
            log.error("newFile: no target or action (tag \(sender.tag, privacy: .public))")
            return
        }
        let url = request.url
        let tag = sender.tag
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = config.afterCreate == .openInMeatPad
        NSWorkspace.shared.open(url, configuration: configuration) { [log] _, error in
            log.notice("newFile: tag \(tag, privacy: .public) -> opened \(error == nil, privacy: .public)")
            if let error {
                let nsError = error as NSError
                log.error("newFile: open failed, \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)")
            }
        }
    }

    /// The sandbox may refuse to stat a selected item; then the URL's own trailing slash
    /// (Finder sends folders with one) is the best answer there is.
    private static func isDirectory(_ url: URL) -> Bool {
        if let value = try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory { return value }
        return url.hasDirectoryPath
    }

    /// Reads the app's `finder.menu` default through the shared-preference read-only
    /// exception — the host app's domain is our own bundle id minus its last component.
    /// `logRead` only at init: a line per right-click is noise.
    private func loadConfig(logRead: Bool = false) -> FinderMenuConfig {
        guard let own = Bundle.main.bundleIdentifier, let dot = own.lastIndex(of: ".") else {
            if logRead { log.error("finder.menu read: no bundle identifier") }
            return FinderMenuConfig()
        }
        let host = String(own[..<dot]) as CFString
        CFPreferencesAppSynchronize(host)
        let value = CFPreferencesCopyAppValue(FinderMenuConfig.defaultsKey as CFString, host)
        if let text = value as? String {
            if logRead { log.notice("finder.menu read: \(text.count, privacy: .public) chars from \(host as String, privacy: .public)") }
            return FinderMenuConfig.decode(Data(text.utf8))
        } else if logRead, value == nil {
            log.notice("finder.menu read: absent in \(host as String, privacy: .public)")
        } else if logRead {
            log.notice("finder.menu read: not a string in \(host as String, privacy: .public)")
        }
        return FinderMenuConfig()
    }
}
