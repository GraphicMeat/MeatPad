import SwiftUI
import AppKit
import MeatPadKit

/// Content view for the `MenuBarExtra("MeatPad")` `.window`-style popover: a title
/// search over the 15 most recently modified notes, plus "New Note" / "All Notes"
/// footer actions.
// ponytail: MenuBarExtra(.window) has no first-party API for a control inside it to
// close the popover (Apple feedback FB11984872; `@Environment(\.dismiss)` is a no-op
// here). Clicking outside dismisses it natively, which is an acceptable P1 fallback.
struct MenuBarNotesView: View {
    // Observed directly: nested ObservableObject changes don't propagate through
    // AppModel's @EnvironmentObject, so the list would go stale on create/trash/save.
    @ObservedObject private var noteStore = AppModel.shared.noteStore
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""

    // ponytail: title-only substring match, no full-text scan. Good enough at P1 note
    // counts; revisit if search needs to cover contents too.
    private var filtered: [Note] {
        let notes = noteStore.notes
        let matched = query.isEmpty
            ? notes
            : notes.filter { $0.title.localizedCaseInsensitiveContains(query) }
        return Array(matched.prefix(15))
    }

    var body: some View {
        ZStack {
            AmbientGlassBackground()
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("MeatPad").font(.headline)
                        Text("Recent notes").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "note.text")
                        .foregroundStyle(MeatPadGlass.tint.gradient)
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)

                GlassSearchField(prompt: "Search notes", text: $query)
                    .padding(10)

                if filtered.isEmpty {
                    ContentUnavailableView(
                        noteStore.notes.isEmpty ? "No notes yet" : "No matches",
                        systemImage: noteStore.notes.isEmpty ? "note.text.badge.plus" : "magnifyingglass"
                    )
                } else {
                    List(filtered) { note in
                        Button { open(note.id) } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "note.text")
                                    .foregroundStyle(MeatPadGlass.tint.gradient)
                                Text(note.title).lineLimit(1)
                                Spacer()
                                RelativeTimeText(date: note.modified)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }

                Divider().opacity(0.45)

                HStack {
                    Button(action: createAndOpen) { Label("New Note", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                    Spacer()
                    Button(action: openBrowser) { Label("All Notes", systemImage: "rectangle.stack") }
                        .buttonStyle(.borderless)
                }
                .padding(10)
            }
        }
        .frame(width: 320, height: 400)
    }

    private func open(_ id: UUID) {
        openWindow(value: id)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createAndOpen() {
        guard let note = try? noteStore.createNote() else { return }
        open(note.id)
    }

    private func openBrowser() {
        openWindow(id: "all-notes")
        NSApp.activate(ignoringOtherApps: true)
    }
}
