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
    @State private var selection = 0
    @FocusState private var focused: Bool

    var body: some View {
        let candidates = candidates

        VStack(spacing: 0) {
            TextField("Quick Open", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .padding(12)
                .focused($focused)
                .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                .onKeyPress(.return) { openSelected(candidates); return .handled }
                .onKeyPress(.escape) { dismiss(); return .handled }

            Divider()

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
                                let candidate = candidates[match.candidateIndex]
                                resultRow(candidate: candidate, match: match, isSelected: row == selection)
                                    .id(row)
                                    .onTapGesture { open(candidate.url) }
                            }
                        }
                    }
                    .onChange(of: selection) { _, newValue in
                        proxy.scrollTo(newValue)
                    }
                }
            }
        }
        .frame(width: 560)
        .frame(maxHeight: 400)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 20)
        .onAppear {
            matches = FuzzyMatcher.rank(query: query, candidates: candidates.map(\.relativePath), limit: 50)
            focused = true
        }
        .task(id: query) {
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            matches = FuzzyMatcher.rank(query: query, candidates: candidates.map(\.relativePath), limit: 50)
            selection = 0
        }
    }

    private var candidates: [(url: URL, relativePath: String)] {
        ProjectScanner.flatFileList(viewModel.tree).map { ($0, Self.relativePath($0, root: viewModel.root)) }
    }

    @ViewBuilder
    private func resultRow(candidate: (url: URL, relativePath: String), match: FuzzyMatcher.Match, isSelected: Bool) -> some View {
        Text(Self.attributed(candidate.relativePath, matchedIndices: match.matchedIndices))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
            .contentShape(Rectangle())
    }

    private func moveSelection(_ delta: Int) {
        guard !matches.isEmpty else { return }
        selection = (selection + delta + matches.count) % matches.count
    }

    private func openSelected(_ candidates: [(url: URL, relativePath: String)]) {
        guard matches.indices.contains(selection) else { return }
        open(candidates[matches[selection].candidateIndex].url)
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
