import SwiftUI
import MeatPadKit
import LanguageServerProtocol

/// ⌘⇧O document symbols: a centered card over the project window's detail pane, same
/// overlay/card/keyboard-nav shape as `QuickOpenView` (Cmd+T) — ranks `viewModel
/// .documentSymbolResults` names against the typed query (`FuzzyMatcher`) instead of file
/// paths, and jumps within the current document instead of switching tabs. Hierarchical
/// results (`DocumentSymbols.flatten`'s `depth`) are shown as one flat, indented list rather
/// than a real tree control — same "flat + fuzzy filter" precedent `QuickOpenView` uses for
/// the project's file tree.
struct DocumentSymbolsView: View {
    @ObservedObject var viewModel: ProjectViewModel

    @State private var query = ""
    @State private var matches: [FuzzyMatcher.Match] = []
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var items: [DocumentSymbols.Item] { viewModel.documentSymbolResults }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "list.bullet.indent")
                    .foregroundStyle(MeatPadGlass.violet.gradient)
                TextField("Search symbols", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .medium))
                    .focused($focused)
                Text("⇧⌘O")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.thinMaterial, in: Capsule())
            }
                .padding(.horizontal, 16)
                .frame(height: 52)
                .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                .onKeyPress(.return) { selectCurrent(); return .handled }
                .onKeyPress(.escape) { dismiss(); return .handled }

            Divider().opacity(0.55)

            if matches.isEmpty {
                Text(items.isEmpty ? "No symbols" : "No matches")
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(matches.enumerated()), id: \.offset) { row, match in
                                if items.indices.contains(match.candidateIndex) {
                                    let item = items[match.candidateIndex]
                                    resultRow(item: item, match: match, isSelected: row == selection)
                                        .id(row)
                                        .onTapGesture { select(item) }
                                }
                            }
                        }
                    }
                    .onChange(of: selection) { _, newValue in
                        proxy.scrollTo(newValue)
                    }
                }
            }
        }
        .frame(width: 580)
        .frame(maxHeight: 420)
        .fixedSize(horizontal: false, vertical: true)
        .glassPanel(cornerRadius: 20)
        .onAppear {
            rerank()
            focused = true
        }
        .task(id: query) {
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            rerank()
            selection = 0
        }
    }

    private func rerank() {
        matches = FuzzyMatcher.rank(query: query, candidates: items.map(\.name), limit: 50)
    }

    @ViewBuilder
    private func resultRow(item: DocumentSymbols.Item, match: FuzzyMatcher.Match, isSelected: Bool) -> some View {
        HStack(spacing: 6) {
            Text(Self.attributed(item.name, matchedIndices: match.matchedIndices))
                .lineLimit(1)
            if let detail = item.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
            .padding(.leading, CGFloat(item.depth) * 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(MeatPadGlass.violet.opacity(0.18)) : AnyShapeStyle(.clear))
            }
            .overlay(alignment: .leading) {
                Capsule().fill(MeatPadGlass.violet)
                    .frame(width: 3, height: 18)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, 7)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    private func moveSelection(_ delta: Int) {
        guard !matches.isEmpty else { return }
        selection = (selection + delta + matches.count) % matches.count
    }

    private func selectCurrent() {
        guard matches.indices.contains(selection) else { return }
        let candidateIndex = matches[selection].candidateIndex
        guard items.indices.contains(candidateIndex) else { return }
        select(items[candidateIndex])
    }

    /// Uses `viewModel.documentSymbolsFile` — the file `showDocumentSymbols` was actually
    /// requested for — rather than `selectedTab`, which can change while the popup is open
    /// (no scrim blocks tab switching/closing) and would otherwise jump in the wrong file
    /// using ranges computed for a different one.
    private func select(_ item: DocumentSymbols.Item) {
        guard let url = viewModel.documentSymbolsFile else { return }
        let text = EditorRegistry.shared.fileViewModel(for: url)?.text ?? ""
        let range = LSPPositionBridge.nsRange(of: item.range, in: text) ?? NSRange(location: 0, length: 0)
        viewModel.open(file: url, reveal: range)
        dismiss()
    }

    private func dismiss() {
        viewModel.documentSymbolsVisible = false
    }

    /// Same Character-offset bolding approach as `QuickOpenView.attributed` — see that
    /// method's doc comment.
    private static func attributed(_ name: String, matchedIndices: [Int]) -> AttributedString {
        let matchedSet = Set(matchedIndices)
        var result = AttributedString()
        for (offset, character) in name.enumerated() {
            var run = AttributedString(String(character))
            if matchedSet.contains(offset) {
                run.inlinePresentationIntent = .stronglyEmphasized
            }
            result += run
        }
        return result
    }
}
