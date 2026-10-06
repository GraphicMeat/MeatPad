import SwiftUI
import AppKit
import MeatPadKit

/// Content of the `WindowGroup("Project", for: URL.self)` scene: a live file-tree sidebar
/// over the given folder, with a tab bar + document editor host as the detail pane.
struct ProjectWindow: View {
    @StateObject private var viewModel: ProjectViewModel
    @StateObject private var searchViewModel: ProjectSearchViewModel
    @ObservedObject private var executor = AppModel.shared.commandExecutor
    @ObservedObject private var zoom = ProjectZoom.shared
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

    /// The executor's untrusted-command prompt, but only when it targets this window's
    /// editor — same host-id filtering as `filterSheetShown`, shaped as an item binding
    /// for `.sheet(item:)` since `CommandTrustSheet` needs the request's payload.
    private var trustRequestForWindow: Binding<CommandTrustRequest?> {
        Binding(
            get: { executor.trustRequest?.context.hostID == AnyHashable(ObjectIdentifier(viewModel)) ? executor.trustRequest : nil },
            set: { if $0 == nil { executor.trustRequest = nil } }
        )
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // Full labels when they fit with room to spare; in a narrow sidebar only the active
                // mode keeps its title and the others shrink to their icons — never a label
                // jammed against the edge of the bar.
                ViewThatFits(in: .horizontal) {
                    sidebarModeBar(compact: false)
                    sidebarModeBar(compact: true)
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
                case .files: FileTreeView(viewModel: viewModel, search: searchViewModel)
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
                    VStack(spacing: 0) {
                        if let output = executor.panelOutput, output.hostID == AnyHashable(ObjectIdentifier(viewModel)) {
                            OutputPanelView(
                                output: output,
                                onClose: { executor.panelOutput = nil },
                                onCancel: { executor.cancel() }
                            )
                        }
                        if viewModel.terminalVisible {
                            TerminalPanelView(project: viewModel, controller: viewModel.terminal)
                        }
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
        .sheet(item: $viewModel.fileTreePrompt) { prompt in
            FileTreeNameSheet(prompt: prompt, project: viewModel)
        }
        .sheet(item: $viewModel.renameRequest) { request in
            RenameSymbolSheet(request: request, project: viewModel)
        }
        .sheet(item: trustRequestForWindow) { request in
            CommandTrustSheet(
                request: request,
                onCancel: { executor.trustRequest = nil },
                onRunOnce: {
                    executor.trustRequest = nil
                    executor.runOnce(request.command, context: request.context)
                },
                onTrustAndRun: {
                    executor.trustRequest = nil
                    executor.trustAndRun(request.command, context: request.context)
                }
            )
        }
        .frame(minWidth: 720, minHeight: 480)
        // ⌘+ / ⌘−: every view below scales its own fonts and fixed sizes by this, and rows that
        // take the default font follow the environment font.
        .environment(\.projectZoom, CGFloat(zoom.scale))
        .environment(\.font, .system(size: 13 * CGFloat(zoom.scale)))
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

    private func sidebarModeBar(compact: Bool) -> some View {
        HStack(spacing: 2) {
            sidebarButton(String(localized: "Files"), icon: "folder", mode: .files, compact: compact)
            sidebarButton(String(localized: "Search"), icon: "magnifyingglass", mode: .search, compact: compact)
            sidebarButton(String(localized: "References"), icon: "arrow.triangle.branch", mode: .references, compact: compact)
        }
    }

    private func sidebarButton(_ title: String, icon: String, mode: ProjectViewModel.SidebarMode, compact: Bool) -> some View {
        let isActive = viewModel.sidebarMode == mode
        return Button {
            withAnimation(.easeOut(duration: 0.16)) { viewModel.sidebarMode = mode }
        } label: {
            Group {
                if compact && !isActive {
                    Image(systemName: icon)
                        .accessibilityLabel(title)
                } else {
                    Label(title, systemImage: icon)
                }
            }
                .zoomFont(.callout, weight: isActive ? .semibold : .medium)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                // Breathing room on both sides of every label, so the widest one (References)
                // sits as far from the bar's edge as Files and Search do.
                .padding(.horizontal, 10 * CGFloat(zoom.scale))
                .frame(maxWidth: .infinity)
                .frame(height: 28 * CGFloat(zoom.scale))
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
        .accessibilityIdentifier(sidebarAccessibilityIdentifier(for: mode))
        .help(title)
        .foregroundStyle(viewModel.sidebarMode == mode ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .frame(maxWidth: .infinity)
    }

    private func sidebarAccessibilityIdentifier(for mode: ProjectViewModel.SidebarMode) -> String {
        switch mode {
        case .files: "project-sidebar-files"
        case .search: "project-sidebar-search"
        case .references: "project-sidebar-references"
        }
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
