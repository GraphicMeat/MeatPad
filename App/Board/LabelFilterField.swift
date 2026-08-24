import SwiftUI
import MeatPadKit

/// The board's label filter, shaped like TomSelect: what you picked stays visible as removable
/// chips, and picking more happens in a typeahead list that also creates a label from whatever
/// you typed. The list rows double as the label manager — swatch, rename, delete — because a
/// separate "Manage Labels" sheet would be a second place to learn for the same four verbs.
struct LabelFilterField: View {
    @ObservedObject var store: BoardStore
    @Binding var selected: Set<UUID>

    @State private var picking = false
    @State private var query = ""
    /// Row the keyboard is on. Index into `matches`, or `matches.count` for the create row.
    @State private var highlight = 0
    @State private var renameTarget: CardLabel?
    @State private var deleteTarget: CardLabel?
    @State private var nameDraft = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "tag")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(selectedLabels) { chip($0) }

            Button {
                query = ""
                highlight = 0
                picking = true
            } label: {
                HStack(spacing: 3) {
                    if selected.isEmpty { Text("Filter by label") }
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("board.labelFilter")
            .popover(isPresented: $picking, arrowEdge: .bottom) { picker }

            if !selected.isEmpty {
                Button("Clear") { selected = [] }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("labelFilter.clear")
            }

            Spacer(minLength: 0)
        }
        // A label deleted while it was being filtered on would otherwise leave an id that
        // shows no chip and matches no card — an empty board with no visible cause.
        .onChange(of: store.labels) { _, labels in
            selected.formIntersection(labels.map(\.id))
        }
        // Alerts hang off the row, not off the popover: a sheet raised from inside a popover
        // dismisses the popover out from under itself.
        .alert("Rename Label", isPresented: renamePresented) {
            TextField("Name", text: $nameDraft)
            Button("Rename") {
                if let target = renameTarget { try? store.renameLabel(id: target.id, to: nameDraft) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(deleteTitle, isPresented: deletePresented, titleVisibility: .visible) {
            Button("Delete Label", role: .destructive) {
                if let target = deleteTarget {
                    selected.remove(target.id)
                    try? store.deleteLabel(id: target.id)
                }
            }
        } message: {
            Text("It is removed from every card that carries it.")
        }
    }

    /// Chips follow the store's order, not the order they were ticked — a filter that
    /// reshuffles itself as you pick is hard to read back.
    private var selectedLabels: [CardLabel] {
        store.labels.filter { selected.contains($0.id) }
    }

    private func chip(_ label: CardLabel) -> some View {
        HStack(spacing: 4) {
            Text(label.name).font(.caption)
            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color(label.color).opacity(0.28)))
        .overlay(Capsule().strokeBorder(Color(label.color).opacity(0.7)))
        .contentShape(Capsule())
        .onTapGesture { selected.remove(label.id) }
        .help(String(localized: "Remove from filter"))
        .accessibilityIdentifier("labelFilter.chip.\(label.name)")
    }

    // MARK: - Picker

    private var picker: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search or create", text: $query)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("labelFilter.search")
                .focused($searchFocused)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.return) { commitHighlight(); return .handled }
                .onKeyPress(.escape) { picking = false; return .handled }
                // Backspace on an empty field drops the last chip, the one TomSelect habit
                // that has no on-screen equivalent.
                .onKeyPress(.delete) {
                    guard query.isEmpty, let last = selectedLabels.last else { return .ignored }
                    selected.remove(last.id)
                    return .handled
                }

            Divider()

            if matches.isEmpty && !canCreate {
                Text(store.labels.isEmpty ? "No labels yet" : "No matches")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { index, label in
                            row(label, highlighted: index == highlight)
                        }
                        if canCreate { createRow }
                    }
                }
                .frame(maxHeight: 260)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(width: 250)
        .onAppear { searchFocused = true }
        .onChange(of: query) { _, _ in highlight = 0 }
    }

    private func row(_ label: CardLabel, highlighted: Bool) -> some View {
        HStack(spacing: 8) {
            // Native picker, so the colour panel, eyedropper and recents come for free. It
            // writes straight through to the store — no Apply button to forget.
            ColorPicker("", selection: colorBinding(label), supportsOpacity: false)
                .labelsHidden()
                .help(String(localized: "Change Color"))
            Button {
                toggle(label.id)
            } label: {
                HStack(spacing: 6) {
                    Text(label.name).font(.callout).lineLimit(1)
                    Spacer(minLength: 4)
                    if selected.contains(label.id) {
                        Image(systemName: "checkmark").font(.caption.weight(.semibold))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("labelFilter.row.\(label.name)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(highlighted ? Color.primary.opacity(0.08) : .clear)
        .contextMenu {
            Button("Rename…") {
                picking = false
                nameDraft = label.name
                renameTarget = label
            }
            Button("Delete…", role: .destructive) {
                picking = false
                deleteTarget = label
            }
        }
    }

    private var createRow: some View {
        Button {
            create()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle").font(.caption)
                Text("Create “\(trimmedQuery)”").font(.callout).lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("labelFilter.create")
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(highlight == matches.count ? Color.primary.opacity(0.08) : .clear)
    }

    // MARK: - Data

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var matches: [CardLabel] {
        guard !trimmedQuery.isEmpty else { return store.labels }
        return FuzzyMatcher.rank(query: trimmedQuery, candidates: store.labels.map(\.name))
            .compactMap { store.labels.indices.contains($0.candidateIndex) ? store.labels[$0.candidateIndex] : nil }
    }

    /// Typing a name that already exists offers the existing label, never a duplicate.
    private var canCreate: Bool {
        !trimmedQuery.isEmpty && !store.labels.contains {
            $0.name.localizedCaseInsensitiveCompare(trimmedQuery) == .orderedSame
        }
    }

    private func colorBinding(_ label: CardLabel) -> Binding<Color> {
        Binding(
            get: { Color(label.color) },
            set: { try? store.setLabelColor(id: label.id, RGBAColor($0)) }
        )
    }

    // MARK: - Actions

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func move(_ delta: Int) {
        let count = matches.count + (canCreate ? 1 : 0)
        guard count > 0 else { return }
        highlight = min(max(0, highlight + delta), count - 1)
    }

    private func commitHighlight() {
        if highlight < matches.count {
            toggle(matches[highlight].id)
        } else if canCreate {
            create()
        }
    }

    /// A created label is filtered on immediately — you typed it to look for it.
    private func create() {
        guard let label = try? store.createLabel(name: trimmedQuery) else { return }
        selected.insert(label.id)
        query = ""
        highlight = 0
    }

    // Hoisted out of the modifier chain, same reason as NotesBrowserWindow's: inline
    // Binding(get:set:) closures there push the type-checker past its budget.
    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    private var deleteTitle: String {
        String(localized: "Delete “\(deleteTarget?.name ?? "")”?")
    }
}
