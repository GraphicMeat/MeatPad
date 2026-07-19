import SwiftUI
import AppKit
import MeatPadKit
import STTextView

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
    var onCursorChange: (Int) -> Void

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

        snippetController?.textView = textView
        textView.onInsertTab = { [weak coord] in MainActor.assumeIsolated { coord?.snippetTab() ?? false } }
        textView.onInsertBacktab = { [weak coord] in MainActor.assumeIsolated { coord?.snippetBacktab() ?? false } }
        textView.onCancel = { [weak coord] in MainActor.assumeIsolated { coord?.snippetCancel() ?? false } }
        textView.onCompletionTrigger = { [weak coord] in MainActor.assumeIsolated { coord?.triggerCompletion() ?? false } }
        textView.onFoldToggle = { [weak coord] fold in MainActor.assumeIsolated { coord?.foldToggle(fold: fold) ?? false } }
        textView.onFoldAll = { [weak coord] in MainActor.assumeIsolated { coord?.foldController.foldAll() } }
        textView.onUnfoldAll = { [weak coord] in MainActor.assumeIsolated { coord?.foldController.unfoldAll() } }
        coord.foldController.attach(to: textView)

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
        @objc func clickBelowText(_ gesture: NSClickGestureRecognizer) {
            guard let textView, let clipView = gesture.view else { return }
            guard !textView.frame.contains(gesture.location(in: clipView)) else { return }
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
                    guard let self, let textView = self.textView, textView.isCompletionActive,
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
                MainActor.assumeIsolated { self?.applyHighlight() }
            }
            pendingHighlight = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }

        /// Full-document reparse + reapply. ponytail: whole-doc every time; fine at P1
        /// scale, swap for a visible-range pass if large files get janky.
        func applyHighlight() {
            // Fold regions ride the same debounce cadence as highlighting — recompute here so
            // the gutter chevrons track edits. Runs even for an empty/unhighlighted buffer so a
            // doc that was just cleared drops its stale chevrons.
            foldController.refresh()
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
                let new = textView.text ?? ""
                if parent.text != new { parent.text = new }
                scheduleHighlight()
                completionController.syncPopup(textView: textView)
            }
        }

        nonisolated func textViewDidChangeSelection(_ notification: Notification) {
            MainActor.assumeIsolated {
                guard let textView, !isUpdatingView else { return }
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

        nonisolated func textView(_ textView: STTextView, completionItemsAtLocation location: any NSTextLocation) -> [any STCompletionItem]? {
            MainActor.assumeIsolated { completionController.completionItems(textView: textView) }
        }

        nonisolated func textView(_ textView: STTextView, insertCompletionItem item: any STCompletionItem) {
            MainActor.assumeIsolated { completionController.insertCompletionItem(item, textView: textView) }
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
