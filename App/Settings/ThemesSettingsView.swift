import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MeatPadKit

/// Settings ▸ Themes: browse builtins (padlock-badged, read-only) + user themes, edit a
/// user theme live (color wells + token colors, with a fixed-size preview), import
/// `.tmTheme` files, and set the active theme. Mirrors the Snippets/Commands panes'
/// list+toolbar shape; the editor column binds straight to the store so every color-well
/// change persists immediately and — when the edited theme is the active one — re-themes
/// every open editor live via `appModel.theme`.
struct ThemesSettingsView: View {
    @ObservedObject var themeStore: ThemeStore
    @EnvironmentObject private var appModel: AppModel
    @State private var selection: String?
    @State private var storeError: String?
    @State private var newCaptureName: String = ""

    /// Working copy of the selected theme: every color-well/toggle edit updates this
    /// immediately (so the preview + `appModel.theme` hot-reload per tick) while the
    /// actual disk write is debounced — see `saveDebouncer`.
    @State private var draft: Theme?
    @State private var saveDebouncer = Debouncer(delay: 0.4)

    private static let sampleCode = """
    // Sample code for live theme preview
    import Foundation

    func fibonacci(_ n: Int) -> Int {
        guard n > 1 else { return n }
        return fibonacci(n - 1) + fibonacci(n - 2)
    }

    let numbers = [1, 2, 3].map { $0 * 2 }
    print("Doubled: \\(numbers)")
    """

    var body: some View {
        HStack(spacing: 0) {
            list
            Divider()
            editor
        }
        .onAppear {
            if selection == nil { selection = appModel.theme.id }
            draft = storedTheme
        }
        .onChange(of: selection) { _, _ in
            saveDebouncer.flush()
            draft = storedTheme
        }
        .onDisappear { saveDebouncer.flush() }
        .alert("Theme Error", isPresented: Binding(get: { storeError != nil }, set: { if !$0 { storeError = nil } })) {
            Button("OK") { storeError = nil }
        } message: {
            Text(storeError ?? "")
        }
    }

    // MARK: - List + toolbar

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(themeStore.allThemes) { theme in
                    row(theme).tag(theme.id)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                for url in urls { importTheme(from: url) }
                return true
            }
            Divider()
            toolbar
        }
        .frame(width: 180)
    }

    private func row(_ theme: Theme) -> some View {
        HStack {
            Text(theme.name)
            Spacer()
            if themeStore.isBuiltin(id: theme.id) {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Built-in — duplicate to customize")
            }
        }
        .contentShape(Rectangle())
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            Button { duplicateSelected() } label: { Image(systemName: "plus.square.on.square") }
                .help("Duplicate as editable copy")
                .disabled(selection == nil)
            Button { deleteSelected() } label: { Image(systemName: "minus") }
                .help("Delete theme")
                .disabled(!isEditable)
            Button { importViaPanel() } label: { Image(systemName: "square.and.arrow.down") }
                .help("Import theme…")
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(8)
    }

    // MARK: - Editor column

    @ViewBuilder
    private var editor: some View {
        if let theme = editingTheme {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(theme.name).font(.headline)
                        Spacer()
                        Button("Use This Theme") { appModel.theme = theme }
                            .disabled(appModel.theme.id == theme.id)
                    }

                    CodeEditor(
                        text: .constant(Self.sampleCode),
                        language: Languages.byID("swift"),
                        theme: theme,
                        onCursorChange: { _ in }
                    )
                    .frame(width: 420, height: 160)
                    .border(.quaternary)

                    if !isEditable {
                        Label("Built-in themes can't be edited — duplicate to customize.", systemImage: "lock.fill")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    editorColorsSection(theme)
                    tokenColorsSection(theme)
                }
                .padding(20)
            }
        } else {
            Text("Select a theme")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func editorColorsSection(_ theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Editor Colors")
                .font(.subheadline.bold())
                .accessibilityIdentifier("themes-editor-colors")
            ColorPicker("Background", selection: colorBinding(theme, \.editorBackground))
            ColorPicker("Foreground", selection: colorBinding(theme, \.editorForeground))
            ColorPicker("Current Line", selection: colorBinding(theme, \.currentLine))
            ColorPicker("Selection", selection: colorBinding(theme, \.selection))
            ColorPicker("Caret", selection: colorBinding(theme, \.caret))
            ColorPicker("Gutter", selection: colorBinding(theme, \.gutterForeground))
            Toggle("Dark Theme", isOn: boolBinding(theme, \.isDark))
        }
        .disabled(!isEditable)
    }

    private func tokenColorsSection(_ theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Token Colors").font(.subheadline.bold())
            ForEach(captureNames(for: theme), id: \.self) { capture in
                ColorPicker(capture, selection: tokenColorBinding(theme, capture))
            }
            HStack {
                TextField("+ capture (e.g. keyword.control)", text: $newCaptureName)
                    .ringlessField()
                    .onSubmit { addCapture(theme) }
                Button("Add") { addCapture(theme) }
                    .disabled(newCaptureName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .disabled(!isEditable)
    }

    // MARK: - Selection helpers

    private var storedTheme: Theme? { selection.flatMap { themeStore.theme(id: $0) } }

    /// The theme the editor renders: the in-flight `draft` while it matches the current
    /// selection (so per-tick color edits show up immediately without waiting on the
    /// debounced disk write), falling back to the stored copy right after a selection
    /// change / on first appear, before `draft` has caught up.
    private var editingTheme: Theme? {
        guard let id = selection else { return nil }
        if let draft, draft.id == id { return draft }
        return storedTheme
    }

    private var isEditable: Bool { selection.map { !themeStore.isBuiltin(id: $0) } ?? false }

    /// Capture list: sorted union of every builtin theme's token keys plus any keys
    /// already present in the theme being edited (so a hand-added or imported capture
    /// still shows a well even if no builtin uses it).
    private func captureNames(for theme: Theme) -> [String] {
        var names = Set(BuiltinThemes.all.flatMap { $0.tokenColors.keys })
        names.formUnion(theme.tokenColors.keys)
        return names.sorted()
    }

    // MARK: - Actions

    private func duplicateSelected() {
        guard let id = selection else { return }
        do {
            let copy = try themeStore.duplicate(id: id)
            selection = copy.id
        } catch {
            storeError = "\(error)"
        }
    }

    private func deleteSelected() {
        guard let id = selection, isEditable else { return }
        // Drop (not flush) any pending debounced write for this theme first — flushing
        // here would resurrect the file `delete` is about to remove.
        saveDebouncer.cancel()
        do {
            try themeStore.delete(id: id)
            // The active theme's underlying file is gone; reflect that in-session
            // immediately rather than silently reverting to it on next launch.
            if appModel.theme.id == id { appModel.theme = BuiltinThemes.defaultDark }
            selection = nil
        } catch {
            storeError = "\(error)"
        }
    }

    private func importViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var types: [UTType] = [.propertyList]
        if let tmtheme = UTType(filenameExtension: "tmtheme") { types.append(tmtheme) }
        panel.allowedContentTypes = types
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            importTheme(from: url)
        }
    }

    private func importTheme(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let theme = try TMThemeImporter.importTheme(data: data)
            try themeStore.save(theme)
            selection = theme.id
        } catch {
            storeError = "\(error)"
        }
    }

    /// Applies an edit immediately (the `draft` + `appModel.theme` reassignment, so the
    /// preview and every open editor re-theme live on every NSColorPanel drag tick), but
    /// debounces the actual disk write — a color drag can fire dozens of times a second
    /// and doesn't need a synchronous JSON write on every one. `onChange(of: selection)`
    /// and `.onDisappear` flush any pending write so an edit can't be lost.
    private func applyEdit(_ theme: Theme) {
        draft = theme
        if appModel.theme.id == theme.id { appModel.theme = theme }
        saveDebouncer.call {
            do {
                try themeStore.save(theme)
            } catch {
                storeError = "\(error)"
            }
        }
    }

    private func addCapture(_ theme: Theme) {
        let name = newCaptureName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var updated = theme
        if updated.tokenColors[name] == nil {
            updated.tokenColors[name] = theme.editorForeground
        }
        applyEdit(updated)
        newCaptureName = ""
    }

    // MARK: - Bindings

    private func colorBinding(_ theme: Theme, _ keyPath: WritableKeyPath<Theme, RGBAColor>) -> Binding<Color> {
        Binding(
            get: { Color(theme[keyPath: keyPath]) },
            set: { newColor in
                var updated = theme
                updated[keyPath: keyPath] = RGBAColor(newColor)
                applyEdit(updated)
            }
        )
    }

    private func boolBinding(_ theme: Theme, _ keyPath: WritableKeyPath<Theme, Bool>) -> Binding<Bool> {
        Binding(
            get: { theme[keyPath: keyPath] },
            set: { newValue in
                var updated = theme
                updated[keyPath: keyPath] = newValue
                applyEdit(updated)
            }
        )
    }

    private func tokenColorBinding(_ theme: Theme, _ capture: String) -> Binding<Color> {
        Binding(
            get: { Color(theme.tokenColors[capture] ?? theme.editorForeground) },
            set: { newColor in
                var updated = theme
                updated.tokenColors[capture] = RGBAColor(newColor)
                applyEdit(updated)
            }
        )
    }
}
