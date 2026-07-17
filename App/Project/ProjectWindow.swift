import SwiftUI
import AppKit
import MeatPadKit

/// Content of the `WindowGroup("Project", for: URL.self)` scene: a live file-tree sidebar
/// over the given folder, with a tab bar + document editor host as the detail pane.
struct ProjectWindow: View {
    @StateObject private var viewModel: ProjectViewModel
    @StateObject private var searchViewModel: ProjectSearchViewModel

    init(root: URL) {
        _viewModel = StateObject(wrappedValue: ProjectViewModel(root: root))
        _searchViewModel = StateObject(wrappedValue: ProjectSearchViewModel(root: root))
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Picker("Sidebar", selection: $viewModel.sidebarMode) {
                    Text("Files").tag(ProjectViewModel.SidebarMode.files)
                    Text("Search").tag(ProjectViewModel.SidebarMode.search)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .padding(8)

                switch viewModel.sidebarMode {
                case .files: FileTreeView(viewModel: viewModel)
                case .search: ProjectSearchView(project: viewModel, viewModel: searchViewModel)
                }
            }
        } detail: {
            DocumentHostView(viewModel: viewModel)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if viewModel.hasTabs { TabBarView(viewModel: viewModel) }
                }
                .overlay {
                    if viewModel.quickOpenVisible {
                        QuickOpenView(viewModel: viewModel)
                    }
                }
        }
        .frame(minWidth: 720, minHeight: 480)
        .navigationTitle(viewModel.root.lastPathComponent)
        // Publish this window's VMs so the focused-window Save/Close/Find commands route here.
        .focusedSceneValue(\.projectViewModel, viewModel)
        .focusedSceneValue(\.projectSearchViewModel, searchViewModel)
        .background(ProjectWindowAccessor(viewModel: viewModel))
        .onAppear {
            AppModel.shared.projectWindowDidAppear(viewModel)
            #if DEBUG
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                viewModel.startTabFlipHarnessIfEnabled()
            }
            #endif
        }
        .onDisappear { AppModel.shared.projectWindowDidDisappear(viewModel) }
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
            viewModel.attach(window: window)
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

private struct FocusedProjectSearchKey: FocusedValueKey {
    typealias Value = ProjectSearchViewModel
}

extension FocusedValues {
    /// The `ProjectViewModel` of the frontmost project window, so app-level Save/Close-Tab
    /// commands act on whichever project window is focused (and fall through to the default
    /// window Close when no project window is focused).
    var projectViewModel: ProjectViewModel? {
        get { self[FocusedProjectKey.self] }
        set { self[FocusedProjectKey.self] = newValue }
    }

    /// The `ProjectSearchViewModel` of the frontmost project window, so Cmd+Shift+F can
    /// refocus its query field even when the sidebar is already showing Search.
    var projectSearchViewModel: ProjectSearchViewModel? {
        get { self[FocusedProjectSearchKey.self] }
        set { self[FocusedProjectSearchKey.self] = newValue }
    }
}
