import SwiftUI
import MeatPadKit

/// Cmd+T fuzzy quick-open: a centered card over the project window's detail pane.
/// Ranks project-relative file paths against the typed query (`FuzzyMatcher`, limit 50);
/// re-ranks per keystroke via `.task(id: query)` — its automatic cancel-on-id-change *is*
/// the 50ms debounce, so no separate `Debouncer` instance is needed here.
struct QuickOpenView: View {
    @ObservedObject var viewModel: ProjectViewModel

    @State private var query = ""
    @State private var matches: [FuzzyMatcher.Match] = []
    @State private var rankedCandidates: [(url: URL, relativePath: String)] = []
    @State private var selection = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle.magnifyingglass")
                    .foregroundStyle(MeatPadGlass.violet.gradient)
                TextField("Search files", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .medium))
                    .focused($focused)
                Text("⌘T")
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
                .onKeyPress(.return) { openSelected(); return .handled }
                .onKeyPress(.escape) { dismiss(); return .handled }

            Divider().opacity(0.55)

            if matches.isEmpty {
                Text(query.isEmpty ? "No files" : "No matches")
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(matches.enumerated()), id: \.offset) { row, match in
                                if rankedCandidates.indices.contains(match.candidateIndex) {
                                    let candidate = rankedCandidates[match.candidateIndex]
                                    resultRow(candidate: candidate, match: match, isSelected: row == selection)
                                        .id(row)
                                        .onTapGesture { open(candidate.url) }
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

    /// Snapshots the current file list into `rankedCandidates` and ranks `matches` against
    /// that SAME array. FSEvents can republish `viewModel.tree` (and thus a fresh `candidates`
    /// list) between renders while the overlay is open; ranking and subscripting against one
    /// stored snapshot keeps `match.candidateIndex` valid for both the list body and Return-to-open.
    private func rerank() {
        let candidates: [(url: URL, relativePath: String)] = ProjectScanner.flatFileList(viewModel.tree).map { ($0, Self.relativePath($0, root: viewModel.root)) }
        rankedCandidates = candidates
        matches = FuzzyMatcher.rank(query: query, candidates: candidates.map(\.relativePath), limit: 50)
    }

    @ViewBuilder
    private func resultRow(candidate: (url: URL, relativePath: String), match: FuzzyMatcher.Match, isSelected: Bool) -> some View {
        Text(Self.attributed(candidate.relativePath, matchedIndices: match.matchedIndices))
            .lineLimit(1)
            .truncationMode(.middle)
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

    private func openSelected() {
        guard matches.indices.contains(selection) else { return }
        let candidateIndex = matches[selection].candidateIndex
        guard rankedCandidates.indices.contains(candidateIndex) else { return }
        open(rankedCandidates[candidateIndex].url)
    }

    private func open(_ url: URL) {
        viewModel.open(file: url)
        dismiss()
    }

    private func dismiss() {
        viewModel.quickOpenVisible = false
    }

    private static func relativePath(_ url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return filePath }
        var relative = String(filePath.dropFirst(rootPath.count))
        if relative.hasPrefix("/") { relative.removeFirst() }
        return relative
    }

    /// `matchedIndices` are Character offsets into `path` (FuzzyMatcher's contract) — walk
    /// `path` by Character and bold matched ones individually, sidestepping any String.Index
    /// vs AttributedString.Index mapping entirely.
    private static func attributed(_ path: String, matchedIndices: [Int]) -> AttributedString {
        let matchedSet = Set(matchedIndices)
        var result = AttributedString()
        for (offset, character) in path.enumerated() {
            var run = AttributedString(String(character))
            if matchedSet.contains(offset) {
                run.inlinePresentationIntent = .stronglyEmphasized
            }
            result += run
        }
        return result
    }
}
