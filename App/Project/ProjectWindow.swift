import SwiftUI
import MeatPadKit

/// Content of the `WindowGroup("Project", for: URL.self)` scene: a live file-tree
/// sidebar over the given folder. Detail pane is a placeholder — Task 7 replaces it
/// with the real tab host.
struct ProjectWindow: View {
    @StateObject private var viewModel: ProjectViewModel

    init(root: URL) {
        _viewModel = StateObject(wrappedValue: ProjectViewModel(root: root))
    }

    var body: some View {
        NavigationSplitView {
            FileTreeView(viewModel: viewModel)
        } detail: {
            VStack(spacing: 8) {
                Text(viewModel.root.lastPathComponent)
                    .font(.title2)
                Text("Select a file")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 480)
        .navigationTitle(viewModel.root.lastPathComponent)
    }
}
