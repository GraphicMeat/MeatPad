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
            ZStack {
                AmbientGlassBackground()
                VStack(spacing: 14) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(MeatPadGlass.violet.gradient)
                    VStack(spacing: 4) {
                        Text(viewModel.root.lastPathComponent)
                            .font(.title2.weight(.semibold))
                        Text("Choose a file from the sidebar or press ⌘T")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 26)
                .glassPanel()
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
    @StateObject private var snippetController = SnippetController(library: AppModel.shared.snippetLibrary)
    @State private var cursor = 0

    var body: some View {
        CodeEditor(
            text: Binding(get: { editor.text }, set: { editor.text = $0 }),
            language: editor.language,
            theme: appModel.theme,
            fontSize: appModel.fontSize,
            softWrap: appModel.softWrap,
            reveal: project.revealTarget,
            onRevealApplied: { project.revealConsumed($0) },
            snippetController: snippetController,
            onCursorChange: { cursor = $0 }
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
            EditorStatusBar(
                text: editor.text,
                cursor: cursor,
                languageOverride: editor.languageOverride,
                language: editor.language,
                onSelectLanguage: { editor.languageOverride = $0 }
            )
        }
        .overlay(alignment: .top) { banner }
        .focusedSceneValue(\.snippetInsertion, SnippetInsertion(languageID: editor.language?.id, insert: { snippetController.insert($0) }))
        .focusedSceneValue(\.editorCommandContext, EditorCommandContext.make(
            hostID: ObjectIdentifier(project),
            panelCapable: true,
            textView: snippetController.textView,
            languageID: editor.language?.id,
            displayName: url.lastPathComponent,
            fileURL: url,
            projectRoot: project.root
        ))
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
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }
}
