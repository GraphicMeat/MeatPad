import AppKit
import MeatPadKit

extension AppModel {

    /// `meatpad://new-file?dir=…&ext=…` from the Finder Sync extension: creates
    /// `Untitled.<ext>` in the folder (never overwriting — "Untitled 2", "Untitled 3", …), then
    /// opens it as a tab or shows it in Finder, as Settings ▸ Finder says. A folder that is
    /// gone or not writable gets an alert naming it, and no file.
    ///
    /// Only a request carrying this install's `finder.token` (what the extension sends) is
    /// acted on silently. The URL scheme is open to any app or web page, so anything else asks
    /// first and creates nothing — no file, no project window, no language server — unless
    /// the user confirms.
    func createFile(for request: NewFileRequest) {
        switch request.trust(expectedToken: FinderMenuSettings.shared.token) {
        case .trusted:
            break
        case .needsConfirmation:
            guard confirmUnauthenticatedRequest(request) else { return }
        }
        let url: URL
        do {
            url = try FileTreeOperations.createUntitledFile(
                withExtension: request.fileExtension, in: request.directory
            )
        } catch {
            presentNewFileError(error, folder: request.directory)
            return
        }
        switch FinderMenuSettings.shared.config.afterCreate {
        case .openInMeatPad:
            open([url])
            NSApp.activate(ignoringOtherApps: true)
        case .showInFinder:
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// File ▸ New File… and the Dock menu's New File…: a save panel offering `Untitled.md` in
    /// `directory` (the focused project's root, when there is one), then an empty file there,
    /// opened as a tab. The panel has already asked about replacing an existing file.
    func newFilePanel(startingIn directory: URL?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Untitled.md"
        panel.canCreateDirectories = true
        if let directory { panel.directoryURL = directory }
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Data().write(to: url)
            } catch {
                self.presentNewFileError(error, folder: url.deletingLastPathComponent())
                return
            }
            self.open([url])
        }
    }

    /// True only when the user presses Create. Cancel is the first button, so Return cancels.
    private func confirmUnauthenticatedRequest(_ request: NewFileRequest) -> Bool {
        let folder = request.directory
        let name = FileManager.default.displayName(atPath: folder.path)
        let ext = request.fileExtension
        let path = folder.path
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Create a new file in “\(name)”?")
        alert.informativeText = String(
            localized: "Another app or a web page asked MeatPad to create an empty “.\(ext)” file in:\n\(path)"
        )
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Create"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func presentNewFileError(_ error: Error, folder: URL) {
        let name = FileManager.default.displayName(atPath: folder.path)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Couldn't create a file in “\(name)”.")
        switch error as? FileTreeError {
        case .directoryMissing:
            alert.informativeText = String(localized: "The folder no longer exists.")
        default:
            alert.informativeText = error.localizedDescription
        }
        alert.addButton(withTitle: String(localized: "OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
