import SwiftUI
import Combine

/// Horizontal strip of open document tabs above the editor. Each tab shows the filename,
/// a dirty dot, and a close button; clicking selects. Selected tab is materially
/// distinct. Hosted via `.safeAreaInset(edge: .top)` on the detail pane.
struct TabBarView: View {
    @ObservedObject var viewModel: ProjectViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(viewModel.tabs, id: \.self) { url in
                    TabItem(
                        url: url,
                        isSelected: viewModel.selectedTab == url,
                        select: { viewModel.selectedTab = url },
                        close: { viewModel.requestClose(url) }
                    )
                    Divider().frame(height: 16)
                }
            }
        }
        .frame(height: 32)
        .background(.bar)
    }
}

/// One tab. Observes the file's VM so the dirty dot tracks edits/saves live.
private struct TabItem: View {
    let url: URL
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    /// May be nil if the file couldn't be read; the tab still renders (host shows the
    /// error), just without a live dirty dot.
    @ObservedObject private var editor: OptionalFileEditor

    @State private var hovering = false

    init(url: URL, isSelected: Bool, select: @escaping () -> Void, close: @escaping () -> Void) {
        self.url = url
        self.isSelected = isSelected
        self.select = select
        self.close = close
        _editor = ObservedObject(wrappedValue: OptionalFileEditor(url: url))
    }

    var body: some View {
        HStack(spacing: 6) {
            // Reserve the dot's slot so the title doesn't shift when it appears; the close
            // button overlays the dot on hover.
            ZStack {
                if editor.isDirty {
                    Image(systemName: "circle.fill").font(.system(size: 6))
                        .foregroundStyle(.secondary)
                        .opacity(hovering ? 0 : 1)
                }
                if hovering {
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .help("Close Tab")
                }
            }
            .frame(width: 12)

            Text(url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: 180)
        .frame(height: 32)
        .background(isSelected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
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
