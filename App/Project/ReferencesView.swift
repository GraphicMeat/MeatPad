import SwiftUI
import MeatPadKit

/// Sidebar "References" mode content (0.7 LSP plan Task 5): Find References results,
/// grouped by file. Shares `MatchResultsList` with `ProjectSearchView` minus the query/replace chrome — this panel is
/// populated by the Navigate ▸ Find References command, not typed into directly. Click a
/// row to open the file and jump to the reference.
struct ReferencesView: View {
    let project: ProjectViewModel

    private var results: [FileMatchGroup] { project.referencesResults }
    private var count: Int { results.reduce(0) { $0 + $1.matches.count } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("References", systemImage: "arrow.triangle.branch")
                    .zoomFont(.headline)
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .zoomFont(.caption, weight: .semibold, monospacedDigit: true)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.thinMaterial, in: Capsule())
                }
            }

            if results.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "arrow.triangle.branch")
                        .zoomFont(.title3)
                        .foregroundStyle(.tertiary)
                    Text("No references found")
                        .zoomFont(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 18)
            } else {
                MatchResultsList(groups: results, root: project.root, open: open)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func open(_ match: SearchMatch) {
        if let range = ProjectSearchViewModel.revealRange(for: match) {
            project.open(file: match.file, reveal: range)
        } else {
            project.open(file: match.file)
        }
    }
}
