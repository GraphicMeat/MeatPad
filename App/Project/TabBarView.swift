import SwiftUI
import AppKit
import Combine
import MeatPadKit

/// Horizontal strip of open document tabs above the editor. Each tab shows the filename,
/// a dirty dot, and a close button; clicking selects. Selected tab is materially
/// distinct. Hosted via `.safeAreaInset(edge: .top)` on the detail pane.
struct TabBarView: View {
    @ObservedObject var viewModel: ProjectViewModel
    @Environment(\.projectZoom) private var zoom
    @Namespace private var tabSelection

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(viewModel.tabs, id: \.self) { url in
                    TabItem(
                        url: url,
                        isSelected: viewModel.selectedTab == url,
                        selectionNamespace: tabSelection,
                        select: { viewModel.selectedTab = url },
                        close: { viewModel.requestClose(url) },
                        makeMenu: { viewModel.tabMenu(for: url) }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(height: 42 * zoom)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) { Divider().opacity(0.4) }
    }
}

/// One tab. Observes the file's VM so the dirty dot tracks edits/saves live.
private struct TabItem: View {
    let url: URL
    let isSelected: Bool
    let selectionNamespace: Namespace.ID
    let select: () -> Void
    let close: () -> Void
    let makeMenu: () -> NSMenu

    /// May be nil if the file couldn't be read; the tab still renders (host shows the
    /// error), just without a live dirty dot.
    @ObservedObject private var editor: OptionalFileEditor

    @State private var hovering = false
    @Environment(\.projectZoom) private var zoom

    init(url: URL, isSelected: Bool, selectionNamespace: Namespace.ID, select: @escaping () -> Void,
         close: @escaping () -> Void, makeMenu: @escaping () -> NSMenu) {
        self.url = url
        self.isSelected = isSelected
        self.selectionNamespace = selectionNamespace
        self.select = select
        self.close = close
        self.makeMenu = makeMenu
        _editor = ObservedObject(wrappedValue: OptionalFileEditor(url: url))
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "doc.text")
                .zoomFont(size: 11, weight: .medium)
                .foregroundStyle(isSelected ? MeatPadGlass.violet : .secondary)

            ZStack {
                if editor.isDirty {
                    Image(systemName: "circle.fill").zoomFont(size: 6)
                        .foregroundStyle(.secondary)
                        .opacity(hovering ? 0 : 1)
                }
                if hovering {
                    Button(action: close) {
                        Image(systemName: "xmark").zoomFont(size: 8, weight: .bold)
                    }
                    .buttonStyle(.plain)
                    .help("Close Tab")
                }
            }
            .frame(width: 11 * zoom)

            Text(url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
                .zoomFont(size: 12, weight: isSelected ? .medium : .regular)
                // On the label, not the tab: an identifier on the row would clobber the
                // close button's. Filenames also show in the file tree, so UI tests need
                // something that says *tab* specifically (`OpenWithUITests`).
                .accessibilityIdentifier("tab-\(url.lastPathComponent)")
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: 180 * zoom)
        .frame(height: 29 * zoom)
        .foregroundStyle(isSelected ? .primary : .secondary)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.white.opacity(0.09))
                    .matchedGeometryEffect(id: "active-tab", in: selectionNamespace)
            } else if hovering {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.white.opacity(0.045))
            }
        }
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(MeatPadGlass.violet)
                .frame(height: 2)
                .padding(.horizontal, 9)
                .opacity(isSelected ? 1 : 0)
        }
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.14)) { select() }
        }
        // Over the tab but out of the way: only a right-click (tab menu), a control-click or a
        // middle-click (both close) hits it. The hover ✕ and plain clicks still reach the tab.
        .overlay { RowContextMenu(makeMenu: { makeMenu() }, onMiddleClick: close, onControlClick: close) }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Wraps the registry's optional file VM in an `ObservableObject` so a `TabItem` can
/// observe dirty changes even when the file failed to load (nil → never dirty).
@MainActor
private final class OptionalFileEditor: ObservableObject {
    let vm: FileEditorViewModel?
    private var cancellable: AnyCancellable?

    var isDirty: Bool { vm?.isDirty ?? false }

    init(url: URL) {
        vm = EditorRegistry.shared.fileViewModel(for: url)
        cancellable = vm?.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }
}
