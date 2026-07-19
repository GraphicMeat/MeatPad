import SwiftUI
import AppKit
import MeatPadKit

/// Settings ▸ Privacy: the same honest claims as `FirstRunView`, where the data actually
/// lives, and full control over it — relocate, export, or permanently delete everything
/// MeatPad has written to disk. Every destructive action here is opt-in, double-confirmed,
/// and uses `NSWorkspace.shared.recycle` (Trash — recoverable), never a direct delete; see
/// `PrivacyDataManager` for the copy/verify logic underneath Relocate and Export.
struct PrivacySettingsView: View {
    @EnvironmentObject private var appModel: AppModel

    @State private var infoAlert: (title: String, message: String)?
    @State private var deleteError: String?

    private var storageBaseURL: URL { URL(fileURLWithPath: appModel.storageRootPath) }

    var body: some View {
        ZStack {
            AmbientGlassBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    claimsPanel
                    storagePanel
                    exportPanel
                    deletePanel
                }
                .padding(24)
            }
        }
        .alert(infoAlert?.title ?? "", isPresented: Binding(get: { infoAlert != nil }, set: { if !$0 { infoAlert = nil } })) {
            Button("OK") { infoAlert = nil }
        } message: {
            Text(infoAlert?.message ?? "")
        }
        .alert("Couldn't Delete Data", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK") { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Privacy")
                .font(.title2.weight(.semibold))
            Text("What MeatPad stores, where it lives, and how to move, export, or erase it.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Claims

    /// Same four lines as `FirstRunView`'s claim list — duplicated rather than shared,
    /// since factoring both call sites onto one shared view would touch that file (owned
    /// by a concurrent reviewer this task) for a handful of lines of text.
    private var claimsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            claim("Notes and settings live on this Mac at \(appModel.storageRootPath) — nothing is uploaded.")
            claim("Commands are real shell scripts. They run only when you invoke them; imported commands ask for confirmation first.")
            claim("Network use is limited to update checks (Sparkle). See below for where your data lives.")
            claim("Code intelligence uses language-server programs already installed on your Mac, running as local processes.")

            Button("Show Welcome Again") {
                UserDefaults.standard.removeObject(forKey: FirstRunView.hasSeenDefaultsKey)
            }
            .padding(.top, 4)
        }
        .padding(14)
        .glassPanel(cornerRadius: 14, shadow: false)
    }

    private func claim(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Storage

    private var storagePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Storage").font(.headline)
            Text(appModel.storageRootPath)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
            HStack {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([storageBaseURL])
                }
                Button("Relocate…") { relocate() }
            }
        }
        .padding(14)
        .glassPanel(cornerRadius: 14, shadow: false)
    }

    /// Copy-then-verify-then-switch: never flips the storage-root override on an
    /// unverified copy, and never deletes the old location — the user restarts to finish.
    private func relocate() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                try PrivacyDataManager.copyManagedArtifacts(from: storageBaseURL, to: destination)
                UserDefaults.standard.set(destination.path, forKey: NoteStore.storageRootOverrideKey)
                infoAlert = (
                    "Storage Relocated",
                    "Restart MeatPad to finish switching to \(destination.path). Your old data is untouched at \(storageBaseURL.path)."
                )
            } catch {
                infoAlert = ("Couldn't Relocate Storage", error.localizedDescription)
            }
        }
    }

    // MARK: - Export

    private var exportPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Export").font(.headline)
            Text("Copies everything MeatPad has stored — notes, snippets, commands, macros, themes, and window session — as plain files into a folder you choose.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Export All Data…") { exportAll() }
        }
        .padding(14)
        .glassPanel(cornerRadius: 14, shadow: false)
    }

    private func exportAll() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        panel.begin { response in
            guard response == .OK, let destinationParent = panel.url else { return }
            let stamp = Self.exportDateFormatter.string(from: Date())
            let exportDir = destinationParent.appendingPathComponent("MeatPad Export \(stamp)", isDirectory: true)
            do {
                try PrivacyDataManager.copyManagedArtifacts(from: storageBaseURL, to: exportDir)
                NSWorkspace.shared.activateFileViewerSelecting([exportDir])
            } catch {
                infoAlert = ("Couldn't Export Data", error.localizedDescription)
            }
        }
    }

    private static let exportDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return formatter
    }()

    // MARK: - Delete All

    private var deletePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Delete Everything").font(.headline)
            Text("Moves every note, snippet, command, macro, theme, and the window session to the Trash, then quits MeatPad. Recoverable from the Trash until you empty it.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Delete All Data…", role: .destructive) { confirmDeleteAll() }
        }
        .padding(14)
        .glassPanel(cornerRadius: 14, shadow: false)
    }

    /// Two blocking `NSAlert`s (same pattern as `MacroCommandItems.promptSaveLastMacro`):
    /// a warning naming every path that will move to the Trash, then a second alert whose
    /// accessory text field must contain the literal word "DELETE" before anything runs.
    /// Recycling is asynchronous — the UserDefaults reset and `NSApp.terminate` happen in
    /// its completion handler so termination can't race ahead of the actual Trash move.
    private func confirmDeleteAll() {
        let artifacts = PrivacyDataManager.existingArtifacts(at: storageBaseURL)
        guard !artifacts.isEmpty else {
            infoAlert = ("Nothing to Delete", "No MeatPad data was found at \(storageBaseURL.path).")
            return
        }

        let warning = NSAlert()
        warning.alertStyle = .critical
        warning.messageText = "Delete All MeatPad Data?"
        warning.informativeText = "This moves the following to the Trash, then quits MeatPad:\n\n"
            + artifacts.map(\.path).joined(separator: "\n")
        warning.addButton(withTitle: "Continue…")
        warning.addButton(withTitle: "Cancel")
        guard warning.runModal() == .alertFirstButtonReturn else { return }

        let confirm = NSAlert()
        confirm.alertStyle = .critical
        confirm.messageText = "Type DELETE to Confirm"
        confirm.informativeText = "This can't be undone once you empty the Trash."
        confirm.addButton(withTitle: "Delete")
        confirm.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "DELETE"
        confirm.accessoryView = field
        confirm.window.initialFirstResponder = field
        guard confirm.runModal() == .alertFirstButtonReturn, field.stringValue == "DELETE" else { return }

        // The completion handler's queue isn't documented as guaranteed-main, so hop
        // explicitly before touching @State or calling into AppKit.
        NSWorkspace.shared.recycle(artifacts) { _, error in
            DispatchQueue.main.async {
                if let error {
                    deleteError = error.localizedDescription
                    return
                }
                for key in Self.resetDefaultsKeys {
                    UserDefaults.standard.removeObject(forKey: key)
                }
                NSApp.terminate(nil)
            }
        }
    }

    /// Every UserDefaults key this app writes (research-enumerated in the 0.8 plan) — reset
    /// alongside the recycled files so the next launch is a genuinely clean slate.
    private static let resetDefaultsKeys = [
        "themeID", "editorFontSize", "softWrap", "recentProjectPaths",
        "filterCommand.script", "filterCommand.input", "filterCommand.output",
        FirstRunView.hasSeenDefaultsKey, NoteStore.storageRootOverrideKey,
    ]
}
