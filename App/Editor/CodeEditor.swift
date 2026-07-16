import SwiftUI
import AppKit
import MeatPadKit
import STTextView

/// SwiftUI wrapper around STTextView (TextKit 2). Signature is consumed by later tasks.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var language: Language?
    var theme: Theme
    var onCursorChange: (Int) -> Void

    /// SF Mono 13 default.
    static let defaultFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = STTextView.scrollableTextView()
        let textView = scrollView.documentView as! STTextView
        let coord = context.coordinator
        coord.textView = textView

        textView.textDelegate = coord
        textView.font = Self.defaultFont
        textView.showsLineNumbers = true
        textView.highlightSelectedLine = true
        textView.isHorizontallyResizable = false // wrap long lines

        textView.text = text
        coord.rebuildHighlighter(languageID: language?.id)
        coord.applyTheme(theme) // sets colors + immediate first highlight paint
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

        coord.applyTheme(theme)
    }

    @MainActor
    final class Coordinator: NSObject, STTextViewDelegate {
        var parent: CodeEditor
        weak var textView: STTextView?
        private(set) var languageID: String?
        private var highlighter: Highlighter?
        private var lastTheme: Theme?
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
            // ponytail: STTextView draws the text selection with the system color
            // (NSColor.selectedTextBackgroundColor) and exposes no per-view hook, so
            // theme.selection is unused until upstream adds one.
            applyHighlight()
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
                [.foregroundColor: NSColor(parent.theme.editorForeground), .font: CodeEditor.defaultFont],
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
