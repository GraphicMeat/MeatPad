import SwiftUI
import AppKit
import MeatPadKit

/// Grouped match list shared by Project Search and References: a file header (chevron,
/// name, folder, count) over compact, hover-highlighted one-line previews with the match
/// tinted in place. Click a row to open the file at the match.
struct MatchResultsList: View {
    let groups: [FileMatchGroup]
    let root: URL
    let open: (SearchMatch) -> Void

    /// Per-file collapse state; absent (default) means expanded.
    @State private var collapsedFiles: Set<URL> = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(MatchListRow.flatten(groups, collapsed: collapsedFiles)) { row in
                    switch row.kind {
                    case .header(let g):
                        let group = groups[g]
                        FileHeader(group: group, root: root, isCollapsed: collapsedFiles.contains(group.file)) {
                            if collapsedFiles.contains(group.file) {
                                collapsedFiles.remove(group.file)
                            } else {
                                collapsedFiles.insert(group.file)
                            }
                        }
                    case .match(let g, let m):
                        let match = groups[g].matches[m]
                        MatchRow(match: match) { open(match) }
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .scrollContentBackground(.hidden)
    }
}

private struct FileHeader: View {
    let group: FileMatchGroup
    let root: URL
    let isCollapsed: Bool
    let toggle: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .zoomFont(size: 9, weight: .bold)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: 10)
                Text(group.file.lastPathComponent)
                    .zoomFont(size: 12, weight: .semibold)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let folder = folder {
                    Text(folder)
                        .zoomFont(size: 11)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 4)
                Text("\(group.matches.count)")
                    .zoomFont(size: 10, weight: .semibold, monospacedDigit: true)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.top, 4)
        .help(FileTreePaths.relativePath(of: group.file, in: root))
        .accessibilityLabel("\(group.file.lastPathComponent), \(group.matches.count)")
    }

    /// Folder the file lives in, relative to the project root; nil for root-level files.
    private var folder: String? {
        let parent = FileTreePaths.relativePath(of: group.file.deletingLastPathComponent(), in: root)
        return parent.isEmpty || parent == "." ? nil : parent
    }
}

private struct MatchRow: View {
    let match: SearchMatch
    let open: () -> Void

    @State private var hovering = false

    var body: some View {
        Text(Self.attributed(match))
            .zoomFont(size: 12)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 22)
            .padding(.trailing, 6)
            .padding(.vertical, 3)
            .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: open)
            .help(String(localized: "Line \(match.lineNumber)"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(match.lineNumber): \(match.lineText)")
            .accessibilityAddTraits(.isButton)
    }

    /// `SearchSnippet.highlight` is UTF-16 into the snippet text; attribute through
    /// `NSMutableAttributedString` in that same space, as the engine does.
    private static func attributed(_ match: SearchMatch) -> AttributedString {
        let snippet = SearchSnippet(match: match)
        let mutable = NSMutableAttributedString(string: snippet.text)
        let range = NSRange(location: snippet.highlight.lowerBound, length: snippet.highlight.count)
        if range.length > 0, range.location + range.length <= mutable.length {
            mutable.addAttributes([
                .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.32),
            ], range: range)
        }
        return AttributedString(mutable)
    }
}
