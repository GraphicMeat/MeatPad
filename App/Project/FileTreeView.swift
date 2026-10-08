import SwiftUI
import AppKit
import MeatPadKit

/// Sidebar file tree: recursive disclosure over `TreeNode`, folder/doc SF Symbols,
/// single click on a file opens it as a tab, double click on a folder's name folds it. The project folder itself is the top row (as in
/// VS Code's Explorer), unfolded at first, and folds the whole tree like any folder.
/// Right-click opens the VS Code-style menu (new, reveal, find, cut/copy/paste, copy path,
/// rename, delete), shaped by Settings ▸ File Tree.
struct FileTreeView: View {
    @ObservedObject var viewModel: ProjectViewModel
    let search: ProjectSearchViewModel
    @Environment(\.projectZoom) private var zoom

    var body: some View {
        List {
            nodeView(viewModel.tree, isRoot: true)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    /// A file is a row; a folder is a disclosure group whose open/closed state lives on the view
    /// model, so a click on the row can fold it as well as the chevron.
    @ViewBuilder
    private func nodeView(_ node: TreeNode, isRoot: Bool = false) -> some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: expansion(of: node.url)) {
                ForEach(node.children ?? [], id: \.id) { child in
                    AnyView(nodeView(child))
                }
            } label: {
                row(for: node, isRoot: isRoot)
            }
        } else {
            row(for: node)
        }
    }

    private func expansion(of url: URL) -> Binding<Bool> {
        Binding(
            get: { viewModel.expandedFolders.contains(url) },
            set: { isOpen in
                if isOpen { viewModel.expandedFolders.insert(url) } else { viewModel.expandedFolders.remove(url) }
            }
        )
    }

    @ViewBuilder
    private func row(for node: TreeNode, isRoot: Bool = false) -> some View {
        let isMenuTarget = viewModel.contextMenuTarget == node.url
        let isSelected = viewModel.selectedTreeItem == node.url
        HStack(spacing: 8) {
            Image(systemName: node.isDirectory ? "folder.fill" : "doc.text")
                .zoomFont(size: 12, weight: .medium)
                .foregroundStyle(node.isDirectory ? AnyShapeStyle(MeatPadGlass.violet.gradient) : AnyShapeStyle(.secondary))
                .frame(width: 16 * zoom)
                // A folder's icon folds and unfolds it, like its chevron. The name and the rest of
                // the row only select (below). Declared first, so it takes the click before the
                // row-wide gesture does.
                .onTapGesture {
                    guard node.isDirectory else { viewModel.selectedTreeItem = node.url; viewModel.open(file: node.url); return }
                    viewModel.selectedTreeItem = node.url
                    withAnimation(.easeOut(duration: 0.15)) { viewModel.toggleFolder(node.url) }
                }
            Text(node.name).lineLimit(1)
                // Explicit: a sidebar List imposes its own row font, so the window's environment font alone doesn't reach it.
                .zoomFont(.body, weight: isRoot ? .semibold : nil)
                .accessibilityValue(isMenuTarget ? Text("Context menu open") : (isSelected ? Text("Selected") : Text(verbatim: "")))
                // On the name, not the row: the window carries the folder's name too.
                .accessibilityIdentifier(isRoot ? "file-tree-root" : "")
                // Double-click on a folder's name folds it, like its chevron and icon. Simultaneous,
                // so the single click still selects at once.
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    guard node.isDirectory else { return }
                    withAnimation(.easeOut(duration: 0.15)) { viewModel.toggleFolder(node.url) }
                })
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                // The name and everything to its right: select only. A file also opens; a folder
                // does not fold on one click — that is the chevron's and the icon's job, or a double-click on the name.
                viewModel.selectedTreeItem = node.url
                if !node.isDirectory { viewModel.open(file: node.url) }
            }
            .overlay {
                RowContextMenu { viewModel.fileTreeMenu(for: node, search: search) }
            }
            // The row's own background, not a view behind its content: it spans the whole row —
            // disclosure chevron and indentation included — so folders and files light up the same.
            // Left-click selects (soft fill); a right-click's target is lit harder, with an outline.
            .listRowBackground(rowHighlight(isMenuTarget: isMenuTarget, isSelected: isSelected))
    }

    @ViewBuilder
    private func rowHighlight(isMenuTarget: Bool, isSelected: Bool) -> some View {
        if isMenuTarget || isSelected {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(isMenuTarget ? 0.28 : 0.20))
                .overlay {
                    if isMenuTarget {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.7), lineWidth: 1)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
        } else {
            Color.clear
        }
    }
}
