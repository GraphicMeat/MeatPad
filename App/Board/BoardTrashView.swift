import SwiftUI
import MeatPadKit

/// Every deleted card, column and board from every board, newest first — the board
/// equivalent of the Notes Trash: one flat list, because a trashed card's own board might
/// itself be sitting in this same list.
struct BoardTrashView: View {
    @ObservedObject var store: BoardStore
    @State private var purgeTarget: TrashEntry?
    @State private var emptyTrashShown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Board Trash").font(.title2.weight(.semibold))
                Spacer()
                Button("Empty Trash") { emptyTrashShown = true }
                    .disabled(store.trash.isEmpty)
                    .accessibilityIdentifier("boardTrash.emptyButton")
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 8)

            if store.trash.isEmpty {
                emptyState
            } else {
                List(store.trash) { entry in
                    row(entry)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { AmbientGlassBackground() }
        .confirmationDialog(
            "Delete everything in Board Trash permanently?",
            isPresented: $emptyTrashShown,
            titleVisibility: .visible
        ) {
            Button("Empty Trash", role: .destructive) { try? store.emptyTrash() }
        } message: {
            Text("This can’t be undone.")
        }
        .confirmationDialog(
            "Delete “\(purgeTarget?.title ?? "")” permanently?",
            isPresented: Binding(get: { purgeTarget != nil }, set: { if !$0 { purgeTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                if let entry = purgeTarget { try? store.purgeTrashEntry(id: entry.id) }
            }
        } message: {
            Text("This can’t be undone.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "trash").font(.largeTitle).foregroundStyle(.tertiary)
            Text("Board Trash Is Empty").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ entry: TrashEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(for: entry.kind))
                .foregroundStyle(MeatPadGlass.tint.gradient)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).lineLimit(1)
                subtitleLine(entry)
            }
            Spacer()
            Button("Restore") { try? store.restoreFromTrash(id: entry.id) }
                .disabled(!canRestore(entry))
                .help(canRestore(entry) ? "" : String(localized: "Its board was deleted too"))
                .accessibilityIdentifier("boardTrash.restore.\(entry.id.uuidString)")
            Button {
                purgeTarget = entry
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Delete Permanently"))
            .accessibilityIdentifier("boardTrash.delete.\(entry.id.uuidString)")
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("boardTrash.row.\(entry.id.uuidString)")
    }

    private func icon(for kind: TrashEntry.Kind) -> String {
        switch kind {
        case .card: return "rectangle.on.rectangle"
        case .column: return "rectangle.split.3x1"
        case .board: return "square.grid.2x2"
        }
    }

    private func subtitleLine(_ entry: TrashEntry) -> some View {
        HStack(spacing: 4) {
            if entry.kind != .board {
                Text("from \(entry.boardName)")
                Text("·")
            }
            if let count = cardCount(entry) {
                Text(cardCountLabel(count))
                Text("·")
            }
            RelativeTimeText(date: entry.deletedAt)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func cardCount(_ entry: TrashEntry) -> Int? {
        switch entry.kind {
        case .card: return nil
        case .column: return entry.columnCards?.count
        case .board: return entry.board?.cards.count
        }
    }

    private func cardCountLabel(_ count: Int) -> String {
        String(AttributedString(localized: "^[\(count) card](inflect: true)").characters)
    }

    /// A card or column can outlive the board it came from — that board was itself deleted
    /// (and trashed separately) afterward — and restoring it then has nowhere to go.
    private func canRestore(_ entry: TrashEntry) -> Bool {
        switch entry.kind {
        case .board: return true
        case .card, .column: return store.boards.contains { $0.id == entry.boardID }
        }
    }
}
