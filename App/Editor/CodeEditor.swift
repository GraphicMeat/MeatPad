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
    var onCursorChange: (Int) -> Void

    /// SF Mono at the given point size.
    static func font(size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = STTextView.scrollableTextView()
        let textView = scrollView.documentView as! STTextView
        let coord = context.coordinator
        coord.textView = textView

        textView.textDelegate = coord
        textView.showsLineNumbers = true
        textView.highlightSelectedLine = true

        textView.text = text
        if let initialCursor, initialCursor <= (text as NSString).length {
            textView.textSelection = NSRange(location: initialCursor, length: 0)
        }
        coord.rebuildHighlighter(languageID: language?.id)
        coord.applyFontSize(fontSize)
        coord.applySoftWrap(softWrap)
        coord.applyTheme(theme) // sets colors + immediate first highlight paint
        coord.applyReveal(reveal) // first render of a just-opened file consumes here
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? STTextView else { return }
        let coord = context.coordinator
        coord.parent = self

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
        weak var textView: STTextView?
        var lastRevealToken: UUID?
        private(set) var languageID: String?
        private var highlighter: Highlighter?
        private var lastTheme: Theme?
        private var lastFontSize: CGFloat?
        private var lastSoftWrap: Bool?
        private var pendingHighlight: DispatchWorkItem?

        init(_ parent: CodeEditor) { self.parent = parent }

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
            // ponytail: STTextView draws the text selection with the system color
            // (NSColor.selectedTextBackgroundColor) and exposes no per-view hook, so
            // theme.selection is unused until upstream adds one.
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
                let new = textView.text ?? ""
                if parent.text != new { parent.text = new }
                scheduleHighlight()
            }
        }

        nonisolated func textViewDidChangeSelection(_ notification: Notification) {
            MainActor.assumeIsolated {
                guard let textView else { return }
                parent.onCursorChange(textView.textSelection.location)
            }
        }
    }
}

extension NSColor {
    /// RGBAColor (sRGB, straight alpha) -> NSColor.
    convenience init(_ c: RGBAColor) {
        self.init(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
    }
}
