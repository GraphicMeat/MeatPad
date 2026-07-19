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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Project Search", systemImage: "text.magnifyingglass")
                    .font(.headline)
                Spacer()
                if viewModel.isSearching {
                    ProgressView().controlSize(.small)
                } else if !viewModel.results.isEmpty {
                    Text("\(viewModel.results.count)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.thinMaterial, in: Capsule())
                }
            }

            GlassSearchField(prompt: String(localized: "Find in files"), text: $viewModel.query, focused: $queryFocused)

            HStack(spacing: 6) {
                toggle("Aa", icon: nil, isOn: $viewModel.caseSensitive, help: String(localized: "Match Case"))
                toggle(String(localized: "Regex"), icon: "asterisk", isOn: $viewModel.isRegex, help: String(localized: "Regular Expression"))
                toggle(String(localized: "Word"), icon: "textformat", isOn: $viewModel.wholeWord, help: viewModel.isRegex ? String(localized: "Not available with regex") : String(localized: "Whole Word"))
                    .disabled(viewModel.isRegex)
            }

            if let error = viewModel.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            Divider().opacity(0.45).padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 7) {
                Text("REPLACE")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                TextField("Replace with", text: $viewModel.replaceText)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 11)
                    .frame(height: 34)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(.white.opacity(0.18), lineWidth: 0.75)
                    }
                Button { viewModel.replaceAll() } label: {
                    Label("Replace All", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.results.isEmpty)
            }
            Divider().opacity(0.45).padding(.vertical, 2)

            results
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { queryFocused = true }
        .onChange(of: viewModel.focusToken) { _, _ in queryFocused = true }
    }

    @ViewBuilder
    private var results: some View {
        if viewModel.results.isEmpty {
            if !viewModel.isSearching {
                VStack(spacing: 7) {
                    Image(systemName: viewModel.query.count >= 2 ? "text.magnifyingglass" : "keyboard")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                    Text(viewModel.query.count >= 2 ? "No matches" : "Type at least 2 characters")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 18)
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
            .scrollContentBackground(.hidden)
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

    private func toggle(_ title: String, icon: String?, isOn: Binding<Bool>, help: String) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            if let icon {
                Label(title, systemImage: icon)
            } else {
                Text(title)
            }
        }
            .buttonStyle(GlassIconButtonStyle(selected: isOn.wrappedValue))
            .font(.caption.weight(.semibold))
            .lineLimit(1)
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
