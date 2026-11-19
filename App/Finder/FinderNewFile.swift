import AppKit
import MeatPadKit

extension AppModel {

    /// `meatpad://new-file?dir=…&ext=…` from the Finder Sync extension: creates
    /// `Untitled.<ext>` in the folder (never overwriting — "Untitled 2", "Untitled 3", …), then
    /// opens it as a tab or shows it in Finder, as Settings ▸ Finder says. A folder that is
    /// gone or not writable gets an alert naming it, and no file.
    func createFile(for request: NewFileRequest) {
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
