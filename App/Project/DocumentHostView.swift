import SwiftUI
import AppKit
import MeatPadKit
import LanguageServerProtocol

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
            symbolIndex: project.symbolIndex,
            currentFileURL: url,
            lspManager: project.lspManager,
            onCursorChange: { cursor = $0 },
            onDocumentChanged: { project.notifyLSPDocumentChanged(url) },
            diagnostics: project.diagnosticsByURI[url.absoluteString] ?? [],
            onGoToDefinition: { offset, screenPoint in
                project.goToDefinition(from: url, languageID: editor.language?.id, offset: offset, screenAnchor: screenPoint)
            }
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
            EditorStatusBar(
                text: editor.text,
                cursor: cursor,
                languageOverride: editor.languageOverride,
                language: editor.language,
                onSelectLanguage: { editor.languageOverride = $0 },
                lspStatus: lspStatusText
            )
        }
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                lspBanner
                banner
            }
        }
        .focusedSceneValue(\.snippetInsertion, SnippetInsertion(languageID: editor.language?.id, insert: { snippetController.insert($0) }))
        .focusedSceneValue(\.editorCommandContext, EditorCommandContext.make(
            hostID: ObjectIdentifier(project),
            panelCapable: true,
            textView: snippetController.textView,
            languageID: editor.language?.id,
            displayName: url.lastPathComponent,
            fileURL: url,
            projectRoot: project.root,
            goToDefinitionAvailable: project.lspStatusByLanguage[editor.language?.id ?? ""] == .running,
            goToDefinition: {
                guard let tv = snippetController.textView else { return }
                let offset = tv.textSelection.location
                let rect = tv.firstRect(forCharacterRange: NSRange(location: offset, length: 0), actualRange: nil)
                project.goToDefinition(from: url, languageID: editor.language?.id, offset: offset, screenAnchor: NSPoint(x: rect.minX, y: rect.minY))
            },
            findReferencesAvailable: project.lspStatusByLanguage[editor.language?.id ?? ""] == .running,
            findReferences: {
                guard let tv = snippetController.textView else { return }
                project.findReferences(from: url, languageID: editor.language?.id, offset: tv.textSelection.location)
            },
            documentSymbolsAvailable: project.lspStatusByLanguage[editor.language?.id ?? ""] == .running,
            documentSymbols: {
                project.showDocumentSymbols(for: url, languageID: editor.language?.id)
            }
        ))
    }

    @ViewBuilder
    private var banner: some View {
        switch project.banners[url] {
        case .changedOnDisk:
            BannerBar(message: String(localized: "File changed on disk")) {
                Button("Reload") { project.reload(url) }
                Button("Keep Mine") { project.dismissBanner(url) }
            }
        case .deleted:
            BannerBar(message: String(localized: "File was deleted on disk")) {
                Button("Dismiss") { project.dismissBanner(url) }
            }
        case nil:
            EmptyView()
        }
    }

    /// Project-wide missing-server notice (not keyed to `url` — see `ProjectViewModel
    /// .lspBanner`), shown over whichever tab happens to be visible.
    @ViewBuilder
    private var lspBanner: some View {
        if let state = project.lspBanner {
            BannerBar(message: String(localized: "No language server found for \(state.languageName)")) {
                Button("Copy Install Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(state.installHint, forType: .string)
                }
                Button("Dismiss") { project.dismissLSPBanner() }
            }
        }
    }

    /// `nil` hides the status item entirely — only files whose language the LSP
    /// manager actually tracks (a `documentOpened` was sent for it) get an entry in
    /// `statusByLanguage`. Appends warning/error counts (e.g. "LSP ✓ 2⚠ 1✕") when this
    /// file has open diagnostics — `EditorStatusBar` itself stays a plain `String` param,
    /// this host composes the full text.
    private var lspStatusText: String? {
        guard let languageID = editor.language?.id,
              let status = project.lspStatusByLanguage[languageID] else { return nil }
        let base: String
        switch status {
        case .running: base = "LSP ✓"
        case .starting: base = "LSP…"
        case .notInstalled, .failed: base = "LSP ✕"
        }

        let diagnostics = project.diagnosticsByURI[url.absoluteString] ?? []
        let warnings = diagnostics.filter { $0.severity == .warning }.count
        let errors = diagnostics.filter { ($0.severity ?? .error) == .error }.count
        var counts: [String] = []
        if warnings > 0 { counts.append("\(warnings)⚠") }
        if errors > 0 { counts.append("\(errors)✕") }
        return counts.isEmpty ? base : "\(base) \(counts.joined(separator: " "))"
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
