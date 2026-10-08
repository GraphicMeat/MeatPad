import SwiftUI
import AppKit
import MeatPadKit

/// Sidebar "Search" mode content (Cmd+Shift+F): query + toggles, replace field, results
/// grouped by file. Click a row to open the file and jump to the match.
struct ProjectSearchView: View {
    let project: ProjectViewModel
    @ObservedObject var viewModel: ProjectSearchViewModel

    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Project Search", systemImage: "text.magnifyingglass")
                    .zoomFont(.headline)
                Spacer()
                if viewModel.isSearching {
                    ProgressView().controlSize(.small)
                } else if !viewModel.results.isEmpty {
                    Text("\(viewModel.results.count)")
                        .zoomFont(.caption, weight: .semibold, monospacedDigit: true)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.thinMaterial, in: Capsule())
                }
            }

            if let scope = viewModel.scopeFolder {
                scopeChip(scope)
            }

            GlassSearchField(
                prompt: String(localized: "Find in files"),
                text: $viewModel.query,
                focused: $queryFocused,
                identifier: "project-search-field"
            )

            HStack(spacing: 6) {
                toggle("Aa", icon: nil, isOn: $viewModel.caseSensitive, help: String(localized: "Match Case"))
                toggle(String(localized: "Regex"), icon: "asterisk", isOn: $viewModel.isRegex, help: String(localized: "Regular Expression"))
                toggle(String(localized: "Word"), icon: "textformat", isOn: $viewModel.wholeWord, help: viewModel.isRegex ? String(localized: "Not available with regex") : String(localized: "Whole Word"))
                    .disabled(viewModel.isRegex)
            }

            if let error = viewModel.errorMessage {
                Text(error).zoomFont(.caption).foregroundStyle(.red)
            }

            Divider().opacity(0.45).padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 7) {
                Text("REPLACE")
                    .zoomFont(.caption2, weight: .semibold)
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
                    .accessibilityIdentifier("project-replace-all")
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

    /// "Find in Folder": shows the folder the search is limited to, with a way back to the
    /// whole project.
    private func scopeChip(_ folder: URL) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").zoomFont(.caption).foregroundStyle(.secondary)
            Text(FileTreePaths.relativePath(of: folder, in: project.root))
                .zoomFont(.caption, weight: .medium)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityIdentifier("project-search-scope")
            Spacer(minLength: 0)
            Button { viewModel.scopeFolder = nil } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Search the whole project"))
            .accessibilityLabel(String(localized: "Clear folder scope"))
            .accessibilityIdentifier("project-search-scope-clear")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.thinMaterial, in: Capsule())
    }

    @ViewBuilder
    private var results: some View {
        if viewModel.results.isEmpty {
            if !viewModel.isSearching {
                VStack(spacing: 7) {
                    Image(systemName: viewModel.query.count >= 2 ? "text.magnifyingglass" : "keyboard")
                        .zoomFont(.title3)
                        .foregroundStyle(.tertiary)
                    Text(viewModel.query.count >= 2 ? "No matches" : "Type at least 2 characters")
                        .zoomFont(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 18)
            }
        } else {
            MatchResultsList(groups: viewModel.groupedResults, root: project.root, open: open)
        }
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
            .zoomFont(.caption, weight: .semibold)
            .lineLimit(1)
            .help(help)
    }
}
