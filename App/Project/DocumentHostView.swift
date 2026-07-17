import SwiftUI
import MeatPadKit

/// Detail pane: the editor for the selected tab, or a placeholder when nothing is open.
struct DocumentHostView: View {
    @ObservedObject var viewModel: ProjectViewModel

    var body: some View {
        if let url = viewModel.selectedTab {
            // Fresh editor instance per document so STTextView state (scroll, selection)
            // never bleeds across tabs.
            DocumentContent(url: url, project: viewModel).id(url)
        } else {
            VStack(spacing: 8) {
                Text(viewModel.root.lastPathComponent).font(.title2)
                Text("Select a file").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Resolves the selected URL's canonical file VM; shows an error if it couldn't load.
private struct DocumentContent: View {
    let url: URL
    @ObservedObject var project: ProjectViewModel

    var body: some View {
        if let editor = EditorRegistry.shared.fileViewModel(for: url) {
            EditorPane(editor: editor, url: url, project: project)
        } else {
            Text("Couldn't open “\(url.lastPathComponent)”.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct EditorPane: View {
    @ObservedObject var editor: FileEditorViewModel
    let url: URL
    @ObservedObject var project: ProjectViewModel
    @ObservedObject private var appModel = AppModel.shared

    var body: some View {
        CodeEditor(
            text: Binding(get: { editor.text }, set: { editor.text = $0 }),
            language: editor.language,
            theme: appModel.theme,
            fontSize: appModel.fontSize,
            softWrap: appModel.softWrap,
            reveal: project.revealTarget,
            onCursorChange: { _ in }
        )
        .overlay(alignment: .top) { banner }
    }

    @ViewBuilder
    private var banner: some View {
        switch project.banners[url] {
        case .changedOnDisk:
            BannerBar(message: "File changed on disk") {
                Button("Reload") { project.reload(url) }
                Button("Keep Mine") { project.dismissBanner(url) }
            }
        case .deleted:
            BannerBar(message: "File was deleted on disk") {
                Button("Dismiss") { project.dismissBanner(url) }
            }
        case nil:
            EmptyView()
        }
    }
}

/// Thin non-modal notice bar over the top of the editor.
private struct BannerBar<Actions: View>: View {
    let message: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(message)
            Spacer()
            actions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}
