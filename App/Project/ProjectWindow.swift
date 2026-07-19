import SwiftUI
import AppKit
import MeatPadKit

/// Content of the `WindowGroup("Project", for: URL.self)` scene: a live file-tree sidebar
/// over the given folder, with a tab bar + document editor host as the detail pane.
struct ProjectWindow: View {
    @StateObject private var viewModel: ProjectViewModel
    @StateObject private var searchViewModel: ProjectSearchViewModel
    @ObservedObject private var executor = AppModel.shared.commandExecutor
    @Namespace private var sidebarSelection

    init(root: URL) {
        _viewModel = StateObject(wrappedValue: ProjectViewModel(root: root))
        _searchViewModel = StateObject(wrappedValue: ProjectSearchViewModel(root: root))
    }

    /// True while the executor's filter request targets this window's editor.
    private var filterSheetShown: Binding<Bool> {
        Binding(
            get: { executor.filterContext?.hostID == AnyHashable(ObjectIdentifier(viewModel)) },
            set: { if !$0 { executor.filterContext = nil } }
        )
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 2) {
                    sidebarButton(String(localized: "Files"), icon: "folder", mode: .files)
                    sidebarButton(String(localized: "Search"), icon: "magnifyingglass", mode: .search)
                    sidebarButton(String(localized: "References"), icon: "arrow.triangle.branch", mode: .references)
                }
                .padding(3)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.white.opacity(0.10), lineWidth: 0.5)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

                switch viewModel.sidebarMode {
                case .files: FileTreeView(viewModel: viewModel)
                case .search: ProjectSearchView(project: viewModel, viewModel: searchViewModel)
                case .references: ReferencesView(project: viewModel)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .background(.ultraThinMaterial)
            .navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 340)
        } detail: {
            DocumentHostView(viewModel: viewModel)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if viewModel.hasTabs { TabBarView(viewModel: viewModel) }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let output = executor.panelOutput, output.hostID == AnyHashable(ObjectIdentifier(viewModel)) {
                        OutputPanelView(
                            output: output,
                            onClose: { executor.panelOutput = nil },
                            onCancel: { executor.cancel() }
                        )
                    }
                }
                .overlay {
                    if viewModel.quickOpenVisible {
                        QuickOpenView(viewModel: viewModel)
                    } else if viewModel.documentSymbolsVisible {
                        DocumentSymbolsView(viewModel: viewModel)
                    }
                }
        }
        .sheet(isPresented: filterSheetShown) {
            if let context = executor.filterContext {
                FilterCommandSheet(context: context, onDismiss: { executor.filterContext = nil })
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

    private func sidebarButton(_ title: String, icon: String, mode: ProjectViewModel.SidebarMode) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) { viewModel.sidebarMode = mode }
        } label: {
            Label(title, systemImage: icon)
                .font(.callout.weight(viewModel.sidebarMode == mode ? .semibold : .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .contentShape(Rectangle())
                .background {
                    if viewModel.sidebarMode == mode {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(.white.opacity(0.10))
                            .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
                            .matchedGeometryEffect(id: "sidebar-mode", in: sidebarSelection)
                    }
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(viewModel.sidebarMode == mode ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .frame(maxWidth: .infinity)
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
