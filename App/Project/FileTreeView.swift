import SwiftUI
import AppKit
import MeatPadKit

/// Sidebar file tree: recursive disclosure over `TreeNode`, folder/doc SF Symbols,
/// single click on a file opens it as a tab. "Reveal in Finder" works on any row.
struct FileTreeView: View {
    @ObservedObject var viewModel: ProjectViewModel

    var body: some View {
        List {
            OutlineGroup(viewModel.tree.children ?? [], id: \.id, children: \.children) { node in
                row(for: node)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func row(for node: TreeNode) -> some View {
        HStack(spacing: 8) {
            Image(systemName: node.isDirectory ? "folder.fill" : "doc.text")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(node.isDirectory ? AnyShapeStyle(MeatPadGlass.violet.gradient) : AnyShapeStyle(.secondary))
                .frame(width: 16)
            Text(node.name).lineLimit(1)
        }
            .contentShape(Rectangle())
            .onTapGesture {
                guard !node.isDirectory else { return }
                viewModel.open(file: node.url)
            }
            .contextMenu {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([node.url])
                }
            }
    }
}
