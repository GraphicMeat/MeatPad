import SwiftUI
import MeatPadKit

/// Sidebar "References" mode content (0.7 LSP plan Task 5): Find References results,
/// grouped by file. Same DisclosureGroup/row shape as `ProjectSearchView`'s results list
/// (`ProjectSearchView.swift:94-111`) minus the query/replace chrome — this panel is
/// populated by the Navigate ▸ Find References command, not typed into directly. Click a
/// row to open the file and jump to the reference.
struct ReferencesView: View {
    let project: ProjectViewModel

    /// Per-file collapse state; absent (default) means expanded — same default as
    /// `ProjectSearchView.collapsedFiles`.
    @State private var collapsedFiles: Set<URL> = []

    private var results: [FileMatchGroup] { project.referencesResults }
    private var count: Int { results.reduce(0) { $0 + $1.matches.count } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("References", systemImage: "arrow.triangle.branch")
                    .font(.headline)
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.thinMaterial, in: Capsule())
                }
            }

            if results.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                    Text("No references found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 18)
            } else {
                List {
                    ForEach(results) { group in
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
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            Text(match.lineText.trimmingCharacters(in: .whitespaces))
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
}
