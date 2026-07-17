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
    }

    @ViewBuilder
    private func row(for node: TreeNode) -> some View {
        Label(node.name, systemImage: node.isDirectory ? "folder" : "doc.text")
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
