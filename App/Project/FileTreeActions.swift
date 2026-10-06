import SwiftUI
import AppKit
import MeatPadKit

/// A New File / New Folder / Rename prompt waiting for a name; `ProjectWindow` shows it as a sheet.
struct FileTreeNamePrompt: Identifiable {
    enum Kind {
        case newFile(in: URL)
        case newFolder(in: URL)
        case rename(URL)
    }
    let id = UUID()
    let kind: Kind

    var initialName: String {
        if case .rename(let url) = kind { return url.lastPathComponent }
        return ""
    }
}

/// The sheet body: `NamePromptSheet` with the right title for the prompt's kind.
struct FileTreeNameSheet: View {
    let prompt: FileTreeNamePrompt
    let project: ProjectViewModel
    @State private var name: String

    init(prompt: FileTreeNamePrompt, project: ProjectViewModel) {
        self.prompt = prompt
        self.project = project
        _name = State(initialValue: prompt.initialName)
    }

    var body: some View {
        switch prompt.kind {
        case .newFile:
            NamePromptSheet(title: "New File", action: "Create", name: $name) { project.commit(prompt, name: name) }
        case .newFolder:
            NamePromptSheet(title: "New Folder", action: "Create", name: $name) { project.commit(prompt, name: name) }
        case .rename:
            NamePromptSheet(title: "Rename", action: "Rename", name: $name) { project.commit(prompt, name: name) }
        }
    }
}

/// Cut is a flag on the system clipboard's current contents: paste moves only while the
/// pasteboard is still the one Cut wrote, so a later Copy anywhere turns it back into a copy.
@MainActor
private enum FileTreeClipboard {
    private static var cut: (changeCount: Int, urls: [URL])?

    static var fileURLs: [URL] {
        let objects = NSPasteboard.general.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        return objects ?? []
    }

    static var hasFiles: Bool { !fileURLs.isEmpty }

    static func write(_ urls: [URL], cut isCut: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        cut = isCut ? (pasteboard.changeCount, urls) : nil
    }

    /// The files to paste, and whether this paste moves them.
    static func contents() -> (urls: [URL], move: Bool) {
        let urls = fileURLs
        let move = cut.map { $0.changeCount == NSPasteboard.general.changeCount } ?? false
        return (urls, move)
    }

    static func consumedCut() { cut = nil }
}

extension ProjectViewModel {

    /// The native menu for a right-click on `node`, built from the user's current settings.
    func fileTreeMenu(for node: TreeNode, search: ProjectSearchViewModel) -> NSMenu {
        let settings = FileTreeMenuSettings.shared.config
        let context = FileTreeMenuContext(
            target: node.url, isDirectory: node.isDirectory, root: root,
            clipboardHasFiles: FileTreeClipboard.hasFiles
        )
        let entries = FileTreeMenu.entries(for: context, config: settings)
        let menu = FileTreeMenuBuilder.menu(for: entries, showIcons: settings.showIcons) { [weak self] action in
            self?.perform(action, on: node, search: search)
        }
        // The row is lit while its menu is open, so it is clear which item the actions apply to.
        contextMenuTarget = node.url
        menu.onClose = { [weak self] in self?.contextMenuTarget = nil }
        return menu
    }

    func perform(_ action: FileTreeAction, on node: TreeNode, search: ProjectSearchViewModel) {
        let url = node.url
        let directory = FileTreePaths.containingDirectory(of: url, isDirectory: node.isDirectory)
        switch action {
        case .newFile: fileTreePrompt = FileTreeNamePrompt(kind: .newFile(in: directory))
        case .newFolder: fileTreePrompt = FileTreeNamePrompt(kind: .newFolder(in: directory))
        case .rename: fileTreePrompt = FileTreeNamePrompt(kind: .rename(url))
        case .revealInFinder: NSWorkspace.shared.activateFileViewerSelecting([url])
        case .openInPreview: openWith(bundleID: "com.apple.Preview", url: url)
        case .openInTerminal: openWith(bundleID: "com.apple.Terminal", url: directory)
        case .findInFolder:
            search.scopeFolder = directory.standardizedFileURL == root.standardizedFileURL ? nil : directory
            sidebarMode = .search
            search.requestFocus()
        case .cut: FileTreeClipboard.write([url], cut: true)
        case .copy: FileTreeClipboard.write([url], cut: false)
        case .paste: paste(into: directory)
        case .copyPath: writeString(url.path)
        case .copyRelativePath: writeString(FileTreePaths.relativePath(of: url, in: root))
        case .delete: trash(url)
        }
    }

    /// Runs the confirmed name from the prompt sheet.
    func commit(_ prompt: FileTreeNamePrompt, name: String) {
        do {
            switch prompt.kind {
            case .newFile(let directory):
                let created = try FileTreeOperations.createFile(named: name, in: directory)
                rescan()
                open(file: created)
            case .newFolder(let directory):
                try FileTreeOperations.createFolder(named: name, in: directory)
                rescan()
            case .rename(let url):
                guard closeTabsForChange(under: url) else { return }
                try FileTreeOperations.rename(url, to: name)
                rescan()
            }
        } catch {
            presentFileTreeError(error)
        }
    }

    private func trash(_ url: URL) {
        guard closeTabsForChange(under: url) else { return }
        do {
            try FileTreeOperations.trash(url)
            rescan()
        } catch {
            presentFileTreeError(error)
        }
    }

    private func paste(into directory: URL) {
        let (urls, move) = FileTreeClipboard.contents()
        guard !urls.isEmpty else { return }
        if move, !urls.allSatisfy(closeTabsForChange(under:)) { return }
        do {
            try FileTreeOperations.paste(urls, into: directory, move: move)
            if move { FileTreeClipboard.consumedCut() }
            rescan()
        } catch {
            presentFileTreeError(error)
        }
    }

    private func writeString(_ string: String) { copyToPasteboard(string) }

    private func openWith(bundleID: String, url: URL) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            presentFileTreeMessage(String(localized: "Couldn't find the app to open “\(url.lastPathComponent)”."))
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Open tabs

    /// Before a rename, move or delete changes where `url` lives: an open tab for it (or for
    /// anything inside it) would point at a path that no longer exists. Clean tabs are closed;
    /// a tab with unsaved edits stops the operation instead, so no edit is ever dropped silently.
    private func closeTabsForChange(under url: URL) -> Bool {
        let prefix = url.standardizedFileURL.path
        let affected = tabs.filter {
            let path = $0.standardizedFileURL.path
            return path == prefix || path.hasPrefix(prefix + "/")
        }
        if let dirty = affected.first(where: { EditorRegistry.shared.fileViewModel(for: $0)?.isDirty == true }) {
            presentFileTreeMessage(String(localized: "“\(dirty.lastPathComponent)” has unsaved changes. Save or close it first."))
            return false
        }
        affected.forEach(closeTab)
        return true
    }

    // MARK: - Errors

    private func presentFileTreeError(_ error: Error) {
        switch error as? FileTreeError {
        case .invalidName: presentFileTreeMessage(String(localized: "That name isn't valid."))
        case .alreadyExists(let name): presentFileTreeMessage(String(localized: "“\(name)” already exists."))
        case .cannotMoveIntoItself: presentFileTreeMessage(String(localized: "A folder can't be moved into itself."))
        case nil: presentFileTreeMessage(error.localizedDescription)
        }
    }

    private func presentFileTreeMessage(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: String(localized: "OK"))
        if let window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
    }
}

// MARK: - Tab menu

extension ProjectViewModel {

    /// Right-click / control-click on a tab: close variants, then the path and Finder actions.
    func tabMenu(for tab: URL) -> NSMenu {
        let showIcons = FileTreeMenuSettings.shared.config.showIcons
        let others = TabSet.others(than: tab, in: tabs)
        let toTheRight = TabSet.toTheRight(of: tab, in: tabs)
        let menu = NSMenu()
        menu.autoenablesItems = false

        func add(_ title: String, _ symbol: String, subtitle: String? = nil, enabled: Bool = true,
                 _ handler: @escaping () -> Void) {
            menu.addItem(FileTreeMenuBuilder.plainItem(
                title: title, symbol: symbol, subtitle: subtitle, isEnabled: enabled,
                showIcons: showIcons, handler: handler
            ))
        }

        add(String(localized: "Close"), "xmark") { [weak self] in self?.requestClose(tab) }
        add(String(localized: "Close Others"), "xmark.square", enabled: !others.isEmpty) { [weak self] in
            others.forEach { self?.requestClose($0) }
        }
        add(String(localized: "Close to the Right"), "arrow.right.to.line", enabled: !toTheRight.isEmpty) { [weak self] in
            toTheRight.forEach { self?.requestClose($0) }
        }
        menu.addItem(.separator())
        add(String(localized: "Copy Path"), "link", subtitle: tab.path) { [weak self] in self?.copyToPasteboard(tab.path) }
        let relative = FileTreePaths.relativePath(of: tab, in: root)
        add(String(localized: "Copy Relative Path"), "arrow.turn.down.right", subtitle: relative) { [weak self] in
            self?.copyToPasteboard(relative)
        }
        menu.addItem(.separator())
        add(String(localized: "Reveal in Finder"), "folder") { NSWorkspace.shared.activateFileViewerSelecting([tab]) }
        return menu
    }

    fileprivate func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
