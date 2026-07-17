import SwiftUI
import AppKit
import MeatPadKit

/// Sidebar "Search" mode content (Cmd+Shift+F): query + toggles, replace field, results
/// grouped by file. Click a row to open the file and jump to the match.
struct ProjectSearchView: View {
    let project: ProjectViewModel
    @ObservedObject var viewModel: ProjectSearchViewModel

    @FocusState private var queryFocused: Bool
    /// Per-file collapse state; absent (default) means expanded, per spec.
    @State private var collapsedFiles: Set<URL> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Search", text: $viewModel.query)
                .textFieldStyle(.roundedBorder)
                .focused($queryFocused)

            HStack(spacing: 4) {
                toggle("Aa", isOn: $viewModel.caseSensitive, help: "Match Case")
                toggle(".*", isOn: $viewModel.isRegex, help: "Regular Expression")
                toggle("\\b", isOn: $viewModel.wholeWord, help: viewModel.isRegex ? "Not available with regex" : "Whole Word")
                    .disabled(viewModel.isRegex)
                Spacer()
            }

            if let error = viewModel.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            Divider().padding(.vertical, 2)

            TextField("Replace", text: $viewModel.replaceText)
                .textFieldStyle(.roundedBorder)
            Button("Replace All") { viewModel.replaceAll() }
                .disabled(viewModel.results.isEmpty)

            Divider().padding(.vertical, 2)

            results
        }
        .padding(8)
        .onAppear { queryFocused = true }
        .onChange(of: viewModel.focusToken) { _, _ in queryFocused = true }
    }

    @ViewBuilder
    private var results: some View {
        if viewModel.results.isEmpty {
            if viewModel.query.count >= 2 {
                Text("No results").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            List {
                ForEach(viewModel.groupedResults) { group in
                    DisclosureGroup(isExpanded: expanded(group.file)) {
                        ForEach(Array(group.matches.enumerated()), id: \.offset) { _, match in
                            row(match).onTapGesture { open(match) }
                        }
                    } label: {
                        Text("\(group.file.lastPathComponent) (\(group.matches.count))")
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func expanded(_ file: URL) -> Binding<Bool> {
        Binding(
            get: { !collapsedFiles.contains(file) },
            set: { isExpanded in
                if isExpanded { collapsedFiles.remove(file) } else { collapsedFiles.insert(file) }
            }
        )
    }

    private func row(_ match: SearchMatch) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(match.lineNumber)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 22, alignment: .trailing)
            Text(Self.highlighted(match))
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    private func open(_ match: SearchMatch) {
        if let range = ProjectSearchViewModel.revealRange(for: match) {
            project.open(file: match.file, reveal: range)
        } else {
            project.open(file: match.file)
        }
    }

    private func toggle(_ title: String, isOn: Binding<Bool>, help: String) -> some View {
        Button(title) { isOn.wrappedValue.toggle() }
            .buttonStyle(.bordered)
            .tint(isOn.wrappedValue ? .accentColor : .secondary)
            .help(help)
    }

    /// `match.rangeInLine` is a UTF-16 `NSRange` into `lineText` (the engine's own
    /// coordinate space) — attribute via `NSMutableAttributedString` in that same space
    /// and bridge to `AttributedString`, rather than converting to `String.Index` and
    /// risking a UTF-16/grapheme-cluster mismatch.
    private static func highlighted(_ match: SearchMatch) -> AttributedString {
        let mutable = NSMutableAttributedString(string: match.lineText)
        let full = NSRange(location: 0, length: mutable.length)
        let range = NSRange(location: match.rangeInLine.lowerBound, length: match.rangeInLine.count)
        if range.location >= 0, range.location + range.length <= full.length {
            mutable.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                .foregroundColor: NSColor.systemOrange,
            ], range: range)
        }
        return AttributedString(mutable)
    }
}
