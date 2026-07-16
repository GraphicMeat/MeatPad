import SwiftUI
import AppKit
import MeatPadKit

/// Content view for the `MenuBarExtra("MeatPad")` `.window`-style popover: a title
/// search over the 15 most recently modified notes, plus "New Note" / "All Notes"
/// footer actions. Rows and footer buttons dismiss the popover after acting, matching
/// how a menu bar quick-access panel is expected to behave.
struct MenuBarNotesView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    // ponytail: title-only substring match, no full-text scan. Good enough at P1 note
    // counts; revisit if search needs to cover contents too.
    private var filtered: [Note] {
        let notes = appModel.noteStore.notes
        let matched = query.isEmpty
            ? notes
            : notes.filter { $0.title.localizedCaseInsensitiveContains(query) }
        return Array(matched.prefix(15))
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search notes", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(8)

            if filtered.isEmpty {
                Text(appModel.noteStore.notes.isEmpty ? "No notes yet" : "No matches")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered) { note in
                    Button { open(note.id) } label: {
                        HStack {
                            Text(note.title).lineLimit(1)
                            Spacer()
                            Text(note.modified, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }

            Divider()

            HStack {
                Button("New Note") { createAndOpen() }
                Spacer()
                Button("All Notes") { openBrowser() }
            }
            .padding(8)
        }
        .frame(width: 320, height: 400)
    }

    private func open(_ id: UUID) {
        openWindow(value: id)
        NSApp.activate(ignoringOtherApps: true)
        dismiss()
    }

    private func createAndOpen() {
        guard let note = try? appModel.noteStore.createNote() else { return }
        open(note.id)
    }

    private func openBrowser() {
        openWindow(id: "all-notes")
        NSApp.activate(ignoringOtherApps: true)
        dismiss()
    }
}
