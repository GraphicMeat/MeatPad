import AppKit
import FinderSync
import os

/// MeatPad's Finder Sync extension: adds "New … File" items to Finder's right-click menu.
///
/// It is deliberately a dumb menu. It runs sandboxed inside Finder's orbit and cannot write
/// outside its container, so a click only opens `meatpad://new-file?dir=…&ext=…`; the
/// (unsandboxed) app creates the file. Finder forwards an item's title, tag, image and
/// action across the process boundary but not its `representedObject`, so items are told
/// apart by `tag`.
final class FinderSync: FIFinderSync {

    private let log = Logger(subsystem: "com.thecoldzero.MeatPad.FinderSync", category: "finder")

    /// Tag → file extension. Index-stable; Finder hands the tag back on click.
    private static let extensions = ["md", "txt"]

    override init() {
        super.init()
        var roots = [URL(fileURLWithPath: "/")]
        roots += FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]
        ) ?? []
        FIFinderSyncController.default().directoryURLs = Set(roots)
        log.notice("init: watching \(roots.count, privacy: .public) root(s)")
        logHostMenuConfig()
    }

    override func beginObservingDirectory(at url: URL) {
        log.notice("observing \(url.path, privacy: .public)")
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        switch menuKind {
        case .contextualMenuForContainer, .contextualMenuForItems:
            break
        default:
            return nil
        }
        logHostMenuConfig()

        let menu = NSMenu(title: "")
        let titles = ["New Markdown File", "New Text File"]
        for (tag, title) in titles.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(newFile(_:)), keyEquivalent: "")
            item.tag = tag
            menu.addItem(item)
        }
        let target = FIFinderSyncController.default().targetedURL()?.path ?? "<nil>"
        log.notice("menu(for: \(menuKind.rawValue, privacy: .public)) target \(target, privacy: .public) -> \(titles.count, privacy: .public) item(s)")
        return menu
    }

    @objc private func newFile(_ sender: NSMenuItem) {
        guard Self.extensions.indices.contains(sender.tag),
              let directory = FIFinderSyncController.default().targetedURL()
        else {
            log.error("newFile: no target (tag \(sender.tag, privacy: .public))")
            return
        }
        var components = URLComponents()
        components.scheme = "meatpad"
        components.host = "new-file"
        components.queryItems = [
            URLQueryItem(name: "dir", value: directory.path),
            URLQueryItem(name: "ext", value: Self.extensions[sender.tag]),
        ]
        guard let url = components.url else {
            log.error("newFile: could not build URL")
            return
        }
        let opened = NSWorkspace.shared.open(url)
        log.notice("newFile: open(\(url.absoluteString, privacy: .public)) -> \(opened, privacy: .public)")
    }

    /// Reads the app's `finder.menu` default through the shared-preference read-only
    /// exception — the host app's domain is our own bundle id minus its last component.
    private func logHostMenuConfig() {
        guard let own = Bundle.main.bundleIdentifier, let dot = own.lastIndex(of: ".") else {
            log.error("finder.menu read: no bundle identifier")
            return
        }
        let host = String(own[..<dot]) as CFString
        CFPreferencesAppSynchronize(host)
        let value = CFPreferencesCopyAppValue("finder.menu" as CFString, host)
        if let text = value as? String {
            log.notice("finder.menu read: \(text.count, privacy: .public) chars from \(host as String, privacy: .public)")
        } else if value == nil {
            log.notice("finder.menu read: absent in \(host as String, privacy: .public)")
        } else {
            log.notice("finder.menu read: not a string in \(host as String, privacy: .public)")
        }
    }
}
