import SwiftUI
import AppKit
import MeatPadKit

/// Content of the `WindowGroup("Project", for: URL.self)` scene: a live file-tree sidebar
/// over the given folder, with a tab bar + document editor host as the detail pane.
struct ProjectWindow: View {
    @StateObject private var viewModel: ProjectViewModel

    init(root: URL) {
        _viewModel = StateObject(wrappedValue: ProjectViewModel(root: root))
    }

    var body: some View {
        NavigationSplitView {
            FileTreeView(viewModel: viewModel)
        } detail: {
            DocumentHostView(viewModel: viewModel)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if viewModel.hasTabs { TabBarView(viewModel: viewModel) }
                }
        }
        .frame(minWidth: 720, minHeight: 480)
        .navigationTitle(viewModel.root.lastPathComponent)
        // Publish this window's VM so the focused-window Save/Close commands route here.
        .focusedSceneValue(\.projectViewModel, viewModel)
        .background(ProjectWindowAccessor(viewModel: viewModel))
    }
}

/// Grabs the hosting NSWindow (for the save/close sheets) and runs the external-change
/// sweep whenever this window becomes key.
private struct ProjectWindowAccessor: NSViewRepresentable {
    let viewModel: ProjectViewModel

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            viewModel.window = window
            context.coordinator.observe(window, viewModel: viewModel)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private var observer: NSObjectProtocol?

        func observe(_ window: NSWindow, viewModel: ProjectViewModel) {
            guard observer == nil else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak viewModel] _ in
                MainActor.assumeIsolated { viewModel?.scanExternalChanges() }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

private struct FocusedProjectKey: FocusedValueKey {
    typealias Value = ProjectViewModel
}

extension FocusedValues {
    /// The `ProjectViewModel` of the frontmost project window, so app-level Save/Close-Tab
    /// commands act on whichever project window is focused (and fall through to the default
    /// window Close when no project window is focused).
    var projectViewModel: ProjectViewModel? {
        get { self[FocusedProjectKey.self] }
        set { self[FocusedProjectKey.self] = newValue }
    }
}
