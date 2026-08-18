import SwiftUI
import AppKit
import MeatPadKit

/// Content view for the `MenuBarExtra("MeatPad")` `.window`-style popover: a full-text
/// (title + content) search via NoteStore's search index, showing the top 15 ranked results,
/// plus "New Note" / "All Notes" footer actions.
// ponytail: MenuBarExtra(.window) has no first-party API for a control inside it to
// close the popover (Apple feedback FB11984872; `@Environment(\.dismiss)` is a no-op
// here). Clicking outside dismisses it natively, which is an acceptable P1 fallback.
struct MenuBarNotesView: View {
    // Observed directly: nested ObservableObject changes don't propagate through
    // AppModel's @EnvironmentObject, so the list would go stale on create/trash/save.
    @ObservedObject private var noteStore = AppModel.shared.noteStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""

    private var matches: [NoteSearchMatch] {
        Array(noteStore.searchIndex.search(query, notes: noteStore.notes).prefix(15))
    }

    private func note(for id: UUID) -> Note? {
        noteStore.notes.first { $0.id == id }
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

                GlassSearchField(prompt: String(localized: "Search notes"), text: $query)
                    .padding(10)

                if matches.isEmpty {
                    // ponytail: ContentUnavailableView's title2 headline dwarfs a 320pt popover; compact hand-rolled state instead.
                    VStack(spacing: 8) {
                        Image(systemName: noteStore.notes.isEmpty ? "note.text.badge.plus" : "magnifyingglass")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                        Text(noteStore.notes.isEmpty ? "No notes yet" : "No matches")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(matches, id: \.noteID) { match in
                        if let note = note(for: match.noteID) {
                            Button { open(note.id) } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: "note.text")
                                        .foregroundStyle(MeatPadGlass.tint.gradient)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(note.title).lineLimit(1)
                                        if match.rangeInExcerpt != nil {
                                            Text(match.excerpt)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    RelativeTimeText(date: note.modified)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
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
                    Button(action: openBoards) {
                        Label("Boards", systemImage: "square.grid.3x1.below.line.grid.1x2")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Boards"))
                    // In menu-bar-only mode the app menu is gone, so this popover is the
                    // only path to Settings.
                    Button { openSettings(); NSApp.activate(ignoringOtherApps: true) } label: {
                        Label("Settings", systemImage: "gearshape")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Settings"))
                }
                .padding(10)
            }
        }
        .frame(width: 320, height: noteStore.notes.isEmpty ? 250 : 400)
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

    private func openBoards() {
        openWindow(id: BoardWindow.windowID)
        NSApp.activate(ignoringOtherApps: true)
    }
}
