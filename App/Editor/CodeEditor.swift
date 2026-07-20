import SwiftUI
import AppKit
import MeatPadKit
import STTextView
import LanguageServerProtocol

/// One-shot "scroll to + select this range" command. A fresh `token` (new UUID) marks a
/// new request; the same token is applied at most once so a live selection is never
/// clobbered on subsequent view updates. Consumed by Task 9 (search-result jumps).
struct RevealTarget: Equatable {
    let token: UUID
    let range: NSRange
}

/// SwiftUI wrapper around STTextView (TextKit 2). Signature is consumed by later tasks.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var language: Language?
    var theme: Theme
    var fontSize: CGFloat = 13
    var softWrap: Bool = true
    /// UTF-16 offset to place the caret at on first appearance (e.g. the note's
    /// persisted cursor). Applied once in `makeNSView` only — never in `updateNSView`,
    /// so it can never fight a live selection the user is making.
    var initialCursor: Int? = nil
    /// When set with a token the Coordinator hasn't seen yet, scroll to + select the
    /// range exactly once. Harmlessly `nil` for tabs/notes.
    var reveal: RevealTarget? = nil
    /// Called (with the consumed token) after a reveal has actually been applied, so the
    /// owner can clear its published target — clearing on confirmed consumption, never on
    /// a timer, means a reveal for a not-yet-open file can't be lost to render timing.
    var onRevealApplied: ((UUID) -> Void)? = nil
    /// Live snippet expansion for this editor. Owned by the hosting window (so the Insert
    /// Snippet menu can reach it too); the Coordinator wires its text view and routes Tab /
    /// Shift+Tab / Esc and buffer edits into it. `nil` disables snippet handling entirely.
    var snippetController: SnippetController? = nil
    /// Project-wide identifier index for Ctrl+Space completion (merge source 2). `nil` for
    /// notes and other project-less surfaces — completion then falls back to document words +
    /// keywords + snippets, unchanged from before the merge.
    var symbolIndex: ProjectSymbolIndex? = nil
    /// This editor's own file, so `symbolIndex.complete(excludingFile:)` can drop its solo
    /// contribution (already covered by the current-document word source). `nil` alongside
    /// `symbolIndex` for project-less surfaces.
    var currentFileURL: URL? = nil
    /// Owns this project's language servers, so Ctrl+Space can lead with LSP completions
    /// (merge source 0) when one's alive for this doc's language. `nil` for notes and other
    /// project-less surfaces — completion then behaves exactly as it did before LSP existed.
    var lspManager: LSPProjectManager? = nil
    var onCursorChange: (Int) -> Void
    /// Fired on the same 150ms debounce as syntax highlighting, after a real text edit
    /// (see `scheduleHighlight`) — the LSP `textDocument/didChange` hook. `nil` for
    /// notes and any other project-less surface.
    var onDocumentChanged: (() -> Void)? = nil
    /// This editor's file's current diagnostics (squiggles + gutter icons), pre-filtered by
    /// URI upstream (`ProjectViewModel.diagnosticsByURI`). Empty for notes and any other
    /// project-less surface — the default, so existing call sites are unaffected.
    var diagnostics: [Diagnostic] = []
    /// Cmd+click go-to-definition (0.7 LSP plan Task 4): fired with the UTF-16 offset under
    /// the click and the click's own screen point (anchor for the multiple-locations
    /// picker). `nil` for notes and other project-less surfaces — `SnippetTextView
    /// .onDefinitionClick` is then never wired up (see `makeNSView`), so Cmd+click behaves
    /// exactly like a plain click, unchanged from before this feature existed.
    var onGoToDefinition: ((Int, NSPoint) -> Void)? = nil

    /// SF Mono at the given point size.
    static func font(size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = SnippetTextView.scrollableTextView()
        let textView = scrollView.documentView as! SnippetTextView
        let coord = context.coordinator
        coord.textView = textView
        // makeNSView runs inside a SwiftUI render pass just like updateNSView: the
        // programmatic text/selection setup below fires delegate callbacks synchronously,
        // and publishing those into the view model would be "Publishing changes from
        // within view updates". Same suppression as updateNSView.
        coord.isUpdatingView = true
        defer { coord.isUpdatingView = false }

        snippetController?.textView = textView
        textView.onInsertTab = { [weak coord] in MainActor.assumeIsolated { coord?.snippetTab() ?? false } }
        textView.onInsertBacktab = { [weak coord] in MainActor.assumeIsolated { coord?.snippetBacktab() ?? false } }
        textView.onCancel = { [weak coord] in MainActor.assumeIsolated { coord?.snippetCancel() ?? false } }
        textView.onCompletionTrigger = { [weak coord] in MainActor.assumeIsolated { coord?.triggerCompletion() ?? false } }
        textView.onFoldToggle = { [weak coord] fold in MainActor.assumeIsolated { coord?.foldToggle(fold: fold) ?? false } }
        textView.onFoldAll = { [weak coord] in MainActor.assumeIsolated { coord?.foldController.foldAll() } }
        textView.onUnfoldAll = { [weak coord] in MainActor.assumeIsolated { coord?.foldController.unfoldAll() } }
        coord.foldController.attach(to: textView)
        coord.lspController.attach(to: textView)

        // Hover tracking (0.7 LSP plan Task 3): only installed for LSP-backed editors — notes
        // and other project-less surfaces (`lspManager == nil`) get no tracking area at all,
        // per the plan's "zero behavior" requirement, not just a request-time no-op.
        if lspManager != nil {
            textView.installHoverTracking()
            textView.onHoverMouseMoved = { [weak coord] event in MainActor.assumeIsolated { coord?.hoverMouseMoved(event) } }
            textView.onHoverDismiss = { [weak coord] in MainActor.assumeIsolated { coord?.lspController.dismissHover() } }
            textView.onDefinitionClick = { [weak coord] point in MainActor.assumeIsolated { coord?.definitionClick(at: point) ?? false } }
        }

        textView.textDelegate = coord
        textView.showsLineNumbers = true
        textView.highlightSelectedLine = true
        // See CompletionController.syncPopup: the built-in heuristic this replaces only keeps
        // the popup open across a letter keystroke, closing it mid-identifier on a digit or
        // underscore.
        textView.shouldDimissCompletionOnSelectionChange = false

        textView.text = text
        if let initialCursor, initialCursor <= (text as NSString).length {
            textView.textSelection = NSRange(location: initialCursor, length: 0)
        }
        coord.rebuildHighlighter(languageID: language?.id)
        coord.applyFontSize(fontSize)
        coord.applySoftWrap(softWrap)
        coord.applyTheme(theme) // sets colors + immediate first highlight paint
        coord.lspController.setDiagnostics(diagnostics)
        coord.applyReveal(reveal) // first render of a just-opened file consumes here
        coord.observeScroll(of: scrollView)

        // STTextView's frame only spans its content, so a short document leaves dead
        // clip-view space below it where clicks land on nothing. Catch those and treat
        // them as "click at end of document" — focus the editor, caret to the end.
        let click = NSClickGestureRecognizer(target: coord, action: #selector(Coordinator.clickBelowText(_:)))
        scrollView.contentView.addGestureRecognizer(click)
        return scrollView
    }

    /// Always report exactly the size SwiftUI proposes. The editor is a scrolling view
    /// that fills its slot; it must never expose STTextView's own intrinsic content size
    /// to SwiftUI. STTextView self-marks `needsUpdateConstraints` and grows its
    /// `intrinsicContentSize` on every `usageBoundsForTextContainer` change as TextKit2
    /// lazily lays a freshly-mounted document out (tab switch = a new STTextView via
    /// `.id(url)`). Without this, each window Update-Constraints pass re-measured a
    /// different detail min/max size, so NavigationSplitView's SplitViewChildController
    /// re-marked the window mid-pass until the per-window pass budget was exhausted —
    /// AppKit's constraint-feedback-loop guard then threw ("more Update Constraints in
    /// Window passes than there are views in the window"), crashing the app.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? STTextView else { return }
        let coord = context.coordinator
        coord.parent = self
        // Programmatic mutations below (setting text resets the caret) fire delegate
        // callbacks synchronously; publishing those back into the view model here would
        // be "Publishing changes from within view updates". Suppress the echo.
        coord.isUpdatingView = true
        defer { coord.isUpdatingView = false }

        if coord.languageID != language?.id {
            coord.rebuildHighlighter(languageID: language?.id)
            coord.scheduleHighlight()
        }

        // Text binding -> view. Guard against the re-entrant loop where our own
        // delegate callback pushed this string into the binding a moment ago.
        if textView.text != text {
            textView.text = text
            coord.scheduleHighlight()
        }

        coord.applyFontSize(fontSize)
        coord.applySoftWrap(softWrap)
        coord.applyTheme(theme)
        coord.lspController.setDiagnostics(diagnostics)

        coord.applyReveal(reveal)
    }

    @MainActor
    final class Coordinator: NSObject, STTextViewDelegate {
        var parent: CodeEditor
        /// True while `updateNSView` applies binding state to the view — delegate
        /// callbacks fired by those programmatic mutations must not publish back.
        var isUpdatingView = false
        weak var textView: STTextView?
        var lastRevealToken: UUID?
        private(set) var languageID: String?
        private var highlighter: Highlighter?
        private var lastTheme: Theme?
        private var lastFontSize: CGFloat?
        private var lastSoftWrap: Bool?
        private var pendingHighlight: DispatchWorkItem?
        /// Pre-edit range of the change in flight, captured in `willChangeTextIn` (where
        /// buffer offsets are unambiguous) and consumed in `didChangeTextIn` — only while a
        /// snippet session is live.
        private var pendingEditRange: NSRange?
        /// Same capture as `pendingEditRange` but unconditional (not gated on a live snippet
        /// session) — `FoldController.refresh()` needs every edit's span to auto-unfold a
        /// region whose folded body was just touched. Holds the pre-edit NSRange (location +
        /// length of the text being replaced/deleted); `didChangeTextIn` combines its length
        /// with the replacement's length so a pure deletion still yields a non-empty span.
        private var pendingFoldEditRange: NSRange?
        /// Owns Ctrl+Space word completion for this editor. Unlike `SnippetController` it has
        /// no external consumer (no menu item reaches into it), so it's just owned here rather
        /// than threaded through `CodeEditor` as a parameter.
        private let completionController = CompletionController()
        /// Per-editor-instance fold state (regions, folded set, gutter chevrons). Owned here so
        /// it lives and dies with the view — never persisted. Recomputed on the highlight
        /// debounce (see `applyHighlight`).
        let foldController = FoldController()
        /// Per-editor-instance diagnostics rendering (squiggles + gutter icons). Same
        /// lifetime as `foldController`; driven from the same 150ms highlight debounce (see
        /// `applyHighlight`) plus a direct call from `updateNSView` for a prompt first paint.
        let lspController = LSPController()
        /// The completion popup is a child window pinned at screen coordinates — it does not
        /// track content scrolling, so a manual scroll must dismiss it. Typing near the
        /// viewport edge autoscrolls the caret and fires the same bounds notification; the
        /// timestamp guard keeps the popup alive through those keystroke-driven scrolls.
        private var scrollObserver: NSObjectProtocol?
        private var lastTextChange = Date.distantPast

        init(_ parent: CodeEditor) { self.parent = parent }

        deinit {
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        }

        /// Click in the clip view below the text view's frame (short document, dead
        /// space): focus the editor and put the caret at the end — for an empty note
        /// that's the first line. Clicks inside the text view pass through untouched.
        ///
        /// Dead space is detected by hit-testing, not frame math: "did the click land
        /// on anything inside the text view subtree?" is the actual question, and
        /// hitTest answers it regardless of how STTextView sizes its frame. The old
        /// `textView.frame.contains(location)` guard misfired whenever the frame
        /// didn't span the full content (then EVERY click read as "dead space" and
        /// yanked the caret to the end of the document right after STTextView had
        /// placed it correctly on mouseDown).
        @objc func clickBelowText(_ gesture: NSClickGestureRecognizer) {
            guard let textView, let clipView = gesture.view else { return }
            let location = gesture.location(in: clipView)
            let hit = clipView.hitTest(clipView.convert(location, to: clipView.superview))
            guard let hit, !hit.isDescendant(of: textView) else { return }
            textView.window?.makeFirstResponder(textView)
            textView.textSelection = NSRange(location: (textView.text as NSString? ?? "").length, length: 0)
        }

        func observeScroll(of scrollView: NSScrollView) {
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Hover is a screen-anchored child window like the completion popup below —
                    // it doesn't track content scrolling either, so any scroll dismisses it.
                    self.lspController.dismissHover()
                    guard let textView = self.textView, textView.isCompletionActive,
                          Date().timeIntervalSince(self.lastTextChange) > 0.15 else { return }
                    textView.cancelComplete(nil)
                }
            }
        }

        // MARK: Snippet key-command forwarding (called from SnippetTextView overrides)

        func snippetTab() -> Bool {
            guard let textView, let controller = parent.snippetController else { return false }
            return controller.handleTab(textView: textView, languageID: parent.language?.id)
        }

        func snippetBacktab() -> Bool {
            guard let textView, let controller = parent.snippetController else { return false }
            return controller.handleShiftTab(textView: textView)
        }

        func snippetCancel() -> Bool {
            guard let textView, let controller = parent.snippetController else { return false }
            return controller.handleEscape(textView: textView)
        }

        /// Cmd+Opt+Left / Cmd+Opt+Right routed from `SnippetTextView.keyDown`. Consumed only
        /// when a fold region actually matched the caret.
        func foldToggle(fold: Bool) -> Bool {
            fold ? foldController.foldAtCaret() : foldController.unfoldAtCaret()
        }

        /// Always consumes Ctrl+Space — the key has no prior meaning in this editor.
        func triggerCompletion() -> Bool {
            guard let textView else { return false }
            completionController.trigger(textView: textView)
            return true
        }

        /// Routed from `SnippetTextView.onHoverMouseMoved` (installed only when `lspManager`
        /// is non-nil — see `makeNSView`). `lspHandle` may still be `nil` here (server starting/
        /// crashed/not installed) — `LSPController.mouseMoved` degrades silently in that case.
        func hoverMouseMoved(_ event: NSEvent) {
            lspController.mouseMoved(event, handle: lspHandle, fileURL: parent.currentFileURL)
        }

        /// Hit-tests a Cmd+click's window-space point to a character offset and forwards it
        /// (plus the click's screen point, the picker's anchor) to `parent.onGoToDefinition`.
        /// Returns `false` — SnippetTextView then falls through to `super.mouseDown`'s normal
        /// click placement — whenever no server is alive for this doc (`lspHandle == nil`,
        /// the same gate the async completion hook uses) or the point doesn't land on text.
        func definitionClick(at pointInWindow: NSPoint) -> Bool {
            guard let textView, let window = textView.window, lspHandle != nil,
                  parent.onGoToDefinition != nil else { return false }
            let screenPoint = window.convertPoint(toScreen: pointInWindow)
            let charIndex = textView.characterIndex(for: screenPoint)
            guard charIndex != NSNotFound else { return false }
            parent.onGoToDefinition?(charIndex, screenPoint)
            return true
        }

        func rebuildHighlighter(languageID: String?) {
            self.languageID = languageID
            highlighter = languageID.flatMap { Highlighter(languageID: $0) }
        }

        /// Setting `textColor`/`font` recolors the whole document, so only touch the
        /// view when the theme actually changed — otherwise every keystroke would
        /// flash-reset the syntax colors until the debounce re-runs.
        func applyTheme(_ theme: Theme) {
            guard lastTheme != theme, let textView else { return }
            lastTheme = theme
            textView.backgroundColor = NSColor(theme.editorBackground)
            textView.textColor = NSColor(theme.editorForeground)
            textView.insertionPointColor = NSColor(theme.caret)
            textView.selectedLineHighlightColor = NSColor(theme.currentLine)
            textView.gutterView?.textColor = NSColor(theme.gutterForeground)
            // textView.backgroundColor's own didSet propagates to gutterView.backgroundColor
            // internally (STTextView.swift), so the gutter strip already tracks the theme
            // instead of falling back to its default system-vibrancy background.
            let selectionColor = NSColor(theme.selection)
            textView.selectedTextBackgroundColor = selectionColor
            // ponytail: inactive-window selection = active selection at half opacity, no
            // separate Theme field for it.
            textView.unemphasizedSelectedTextBackgroundColor = selectionColor.withAlphaComponent(selectionColor.alphaComponent * 0.5)
            applyHighlight()
        }

        /// Setting `.font` recolors the whole document (same as `applyTheme`), so guard
        /// on actual change to avoid a per-keystroke reset; re-run highlighting after so
        /// token colors land on top of the new font run.
        func applyFontSize(_ size: CGFloat) {
            guard lastFontSize != size, let textView else { return }
            lastFontSize = size
            textView.font = CodeEditor.font(size: size)
            applyHighlight()
        }

        func applySoftWrap(_ wrap: Bool) {
            guard lastSoftWrap != wrap, let textView else { return }
            lastSoftWrap = wrap
            textView.isHorizontallyResizable = !wrap // wrap == view width tracks text width
        }

        /// One-shot reveal: the token is consumed synchronously (so a make + update pass
        /// in the same render cycle can't double-apply), but the scroll/select and the
        /// consumed-callback run on the next main-queue turn — by then a freshly made
        /// view is in its window (so scrollRangeToVisible has real layout to work with),
        /// and mutating the owner's @Published target is safely outside the view update.
        func applyReveal(_ reveal: RevealTarget?) {
            guard let reveal, lastRevealToken != reveal.token else { return }
            lastRevealToken = reveal.token
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let textView = self.textView else { return }
                    if reveal.range.upperBound <= (textView.text as NSString? ?? "").length {
                        textView.textSelection = reveal.range
                        textView.scrollRangeToVisible(reveal.range)
                    }
                    self.parent.onRevealApplied?(reveal.token)
                }
            }
        }

        func scheduleHighlight() {
            pendingHighlight?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.applyHighlight()
                    self?.parent.onDocumentChanged?()
                }
            }
            pendingHighlight = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }

        /// Full-document reparse + reapply. ponytail: whole-doc every time; fine at P1
        /// scale, swap for a visible-range pass if large files get janky.
        func applyHighlight() {
            // Diagnostics gutter markers cleared BEFORE fold's own rebuild — see
            // LSPController.clearGutterMarkersForFoldPass's doc comment (a marker left over
            // from the previous pass would otherwise block a fold chevron from landing on
            // that same line, even after the diagnostic itself has cleared).
            lspController.clearGutterMarkersForFoldPass()
            // Fold regions ride the same debounce cadence as highlighting — recompute here so
            // the gutter chevrons track edits. Runs even for an empty/unhighlighted buffer so a
            // doc that was just cleared drops its stale chevrons.
            foldController.refresh()
            // Diagnostics re-applied AFTER every highlight pass below: `setAttributes`'s
            // full-range reset wipes underline attributes along with everything else, so this
            // must run last regardless of which path through this method is taken.
            defer { lspController.render() }
            guard let textView, let highlighter else { return }
            let source = textView.text ?? ""
            let full = NSRange(location: 0, length: (source as NSString).length)
            guard full.length > 0 else { return }

            highlighter.setText(source)
            textView.setAttributes(
                [.foregroundColor: NSColor(parent.theme.editorForeground), .font: CodeEditor.font(size: parent.fontSize)],
                range: full
            )
            for span in highlighter.highlights(in: full) {
                guard let color = parent.theme.color(forCapture: span.capture) else { continue }
                textView.addAttributes([.foregroundColor: NSColor(color)], range: span.range)
            }
        }

        // MARK: STTextViewDelegate

        // STTextViewDelegate is nonisolated; STTextView only ever calls these on the
        // main thread, so hop back onto the main actor to touch the view/binding.
        nonisolated func textViewDidChangeText(_ notification: Notification) {
            MainActor.assumeIsolated {
                guard let textView else { return }
                lastTextChange = Date()
                lspController.dismissHover()
                let new = textView.text ?? ""
                if parent.text != new { parent.text = new }
                scheduleHighlight()
                completionController.syncPopup(textView: textView)
            }
        }

        nonisolated func textViewDidChangeSelection(_ notification: Notification) {
            MainActor.assumeIsolated {
                guard let textView, !isUpdatingView else { return }
                lspController.dismissHover()
                parent.onCursorChange(textView.textSelection.location)
                parent.snippetController?.caretDidMove(to: textView.textSelection.location)
                completionController.syncPopup(textView: textView)
            }
        }

        // Snippet mirror sync needs the ranged edit callbacks: capture the pre-edit range in
        // `willChange` (buffer offsets are stable there), act on it in `didChange` (buffer now
        // holds the primary edit, so the session's returned mirror edits land in valid
        // coordinates). Skipped entirely when no session is live.
        nonisolated func textView(_ textView: STTextView, willChangeTextIn affectedCharRange: NSTextRange, replacementString: String) {
            MainActor.assumeIsolated {
                let range = SnippetController.nsRange(affectedCharRange, in: textView.textContentManager)
                pendingFoldEditRange = range
                if parent.snippetController?.isSessionActive == true {
                    pendingEditRange = range
                }
            }
        }

        nonisolated func textView(_ textView: STTextView, didChangeTextIn affectedCharRange: NSTextRange, replacementString: String) {
            MainActor.assumeIsolated {
                if let range = pendingFoldEditRange {
                    pendingFoldEditRange = nil
                    let span = max(range.length, replacementString.utf16.count)
                    foldController.noteEdit(range.location..<(range.location + span))
                }
                guard let controller = parent.snippetController, let range = pendingEditRange else { return }
                pendingEditRange = nil
                controller.textDidChange(range: range, replacement: replacementString, textView: textView)
            }
        }

        // MARK: STTextViewDelegate — Ctrl+Space completion (forwarded to CompletionController)

        /// This doc's live server handle, or `nil` if there isn't one — no server detected for
        /// the language, still starting, crashed, or this is a project-less surface (notes).
        /// Non-nil is also the gate the sync completion hook below uses to hand off to the
        /// async one (see its doc comment): LSP completion needs a real request/response round
        /// trip, which the sync hook can't do.
        private var lspHandle: LSPServerHandle? {
            guard let languageID = parent.language?.id, let lspManager = parent.lspManager,
                  lspManager.statusByLanguage[languageID] == .running else { return nil }
            return lspManager.server(for: languageID)
        }

        /// Sync completion hook — STTextView's `complete(_:)` tries this first (see
        /// STTextView+Complete.swift's `performSyncCompletion`) and only falls through to the
        /// async hook below when this returns `nil`. Returning `nil` here whenever a server is
        /// alive routes every LSP-backed doc through that async path instead; every other doc
        /// (no server, or a project-less surface) is handled right here, unchanged from before
        /// LSP completion existed — same function, same behavior, zero added latency.
        nonisolated func textView(_ textView: STTextView, completionItemsAtLocation location: any NSTextLocation) -> [any STCompletionItem]? {
            MainActor.assumeIsolated {
                guard lspHandle == nil else { return nil }
                return completionController.completionItems(
                    textView: textView,
                    languageID: parent.language?.id,
                    symbolIndex: parent.symbolIndex,
                    currentFileURL: parent.currentFileURL,
                    snippetController: parent.snippetController
                )
            }
        }

        /// Async completion hook — only reached when the sync hook above returned `nil`, i.e.
        /// only for docs with a live LSP server (see `lspHandle`). `Coordinator` is already
        /// `@MainActor`, so — unlike the sync hook, which must stay `nonisolated` to satisfy the
        /// fork's non-async protocol requirement — this can be a plain MainActor-isolated method
        /// satisfying the fork's *async* requirement directly: callers already `await` it, so
        /// the implicit actor hop that requires is exactly what a normal MainActor method gets
        /// for free (STTextView's own demo delegate does the same — see
        /// `PrimaryTextEditViewController.textView(_:completionItemsAtLocation:)` upstream).
        func textView(_ textView: STTextView, completionItemsAtLocation location: any NSTextLocation) async -> [any STCompletionItem]? {
            await completionController.completionItemsAsync(
                textView: textView,
                languageID: parent.language?.id,
                symbolIndex: parent.symbolIndex,
                currentFileURL: parent.currentFileURL,
                snippetController: parent.snippetController,
                lspHandle: lspHandle,
                fileURL: parent.currentFileURL
            )
        }

        nonisolated func textView(_ textView: STTextView, insertCompletionItem item: any STCompletionItem) {
            MainActor.assumeIsolated {
                completionController.insertCompletionItem(item, textView: textView, snippetController: parent.snippetController)
            }
        }

        nonisolated func textViewCompletionViewController(_ textView: STTextView) -> any STCompletionViewControllerProtocol {
            MainActor.assumeIsolated { WordCompletionViewController() }
        }
    }
}

extension NSColor {
    /// RGBAColor (sRGB, straight alpha) -> NSColor.
    convenience init(_ c: RGBAColor) {
        self.init(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
    }
}
