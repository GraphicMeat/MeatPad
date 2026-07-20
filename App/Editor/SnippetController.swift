import AppKit
import SwiftUI
import MeatPadKit
import STTextView

/// STTextView 2.3.10's delegate has no `doCommandBy:` seam, so the only way to intercept
/// Tab / Shift+Tab / Esc is to subclass and override the standard responder selectors the
/// key bindings route to (`insertTab:` / `insertBacktab:` / `cancelOperation:`).
/// `STTextView.scrollableTextView()` builds its document view with `Self()`, so calling it
/// on this subclass yields a `SnippetTextView` with no other plumbing changed. Each closure
/// returns true to consume the key (a live snippet handled it), false to fall through to the
/// normal behaviour (literal tab, completion trigger on Esc).
///
/// Ctrl+Space (word completion, Task 8) rides the same seam but can't be caught the same way:
/// AppKit's default key-binding table only maps Option-Esc/F13 to `complete:`, not Ctrl+Space,
/// so there's no `NSStandardKeyBindingResponding` selector to override. It's recognized at the
/// raw key-event level in `keyDown(with:)` instead.
final class SnippetTextView: STTextView {
    var onInsertTab: (() -> Bool)?
    var onInsertBacktab: (() -> Bool)?
    var onCancel: (() -> Bool)?
    var onCompletionTrigger: (() -> Bool)?
    /// Fold (true) / unfold (false) the region at the caret. Returns true to consume the key.
    var onFoldToggle: ((_ fold: Bool) -> Bool)?
    /// Fold All / Unfold All, routed from the Edit menu via `EditorCommandContext`.
    var onFoldAll: (() -> Void)?
    var onUnfoldAll: (() -> Void)?
    /// Hover-tracking seam (0.7 LSP plan Task 3). `mouseMoved` always calls `super` first —
    /// preserving STTextView's own `inputContext` forwarding (marked text / IME) — before this
    /// hook runs, so hover tracking never changes that behavior. Only wired up (and the
    /// tracking area only installed, via `installHoverTracking()`) when `CodeEditor.makeNSView`
    /// sees a live `lspManager` — notes and other project-less surfaces get neither, so there's
    /// no dead tracking area or closure call for a feature that can never fire there.
    var onHoverMouseMoved: ((NSEvent) -> Void)?
    /// Fired on `mouseExited` (cursor left the text view) and `resignFirstResponder` (editor
    /// lost focus) — both are hover dismiss triggers per the 0.7 LSP plan.
    var onHoverDismiss: (() -> Void)?
    /// Cmd+click go-to-definition (0.7 LSP plan Task 4), checked in `mouseDown` below.
    /// Takes the raw window-space click point; returns `true` when it fired a request
    /// (consuming the click) or `false` to fall through to normal click placement — no
    /// live server for this doc, or the click didn't land on text. Only wired up (like
    /// `onHoverMouseMoved`) when `CodeEditor.makeNSView` sees a live `lspManager`, so
    /// Cmd+click on a project-less surface (notes) is untouched: plain click placement,
    /// same as before this feature existed. Cmd+click is free to claim here — the fork's
    /// own `mouseDown` (STTextView+Mouse.swift) only special-cases Shift/Control/Option,
    /// never Command, and multi-caret already owns Option+Click (see below) — verified by
    /// reading the fork source, not just by "it happened not to conflict."
    var onDefinitionClick: ((NSPoint) -> Bool)?

    /// `.inVisibleRect` keeps the tracking area's rect in sync with the view's own bounds as it
    /// resizes/scrolls, so this only needs to run once (`makeNSView`, not `updateTrackingAreas`).
    func installHoverTracking() {
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onHoverMouseMoved?(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverDismiss?()
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        onHoverDismiss?()
        return result
    }

    override func insertTab(_ sender: Any?) {
        if onInsertTab?() == true { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if onInsertBacktab?() == true { return }
        super.insertBacktab(sender)
    }

    /// Snippet precedence: while a live snippet's Esc-cancel doesn't apply (no session, or the
    /// session declined it), fall back only to dismissing the completion popup if one is
    /// showing — never to `super.cancelOperation`. STTextView's own `cancelOperation` override
    /// treats a not-currently-visible popup as "nothing to cancel, so trigger completion
    /// instead," which would make plain Esc a second way to open the Ctrl+Space popup.
    override func cancelOperation(_ sender: Any?) {
        // Multi-caret collapse takes priority: with >1 caret/range, Esc collapses to the first
        // BEFORE any snippet/completion handling.
        if MultiCaretController.collapseToFirst(self) { return }
        if onCancel?() == true { return }
        if isCompletionActive {
            cancelComplete(sender)
        }
    }

    /// Option+Click appends a caret. STTextView consumes plain option-click for block/visual
    /// selection and its `appendInsertionPointSelection` hook is module-internal, so snapshot the
    /// current selections, let `super` place a single caret at the click (native point → caret
    /// conversion, no gutter/scroll math), then merge the snapshot back via MultiCaretController.
    override func mouseDown(with event: NSEvent) {
        if event.type == .leftMouseDown,
           event.modifierFlags.intersection([.command, .option, .shift, .control]) == .command {
            // Always place the caret natively first (synchronous) so an empty definition
            // response (comment/keyword/whitespace) still matches Xcode's Cmd+click parity.
            // Async navigation/reveal from onDefinitionClick overrides the caret later when a
            // definition resolves.
            super.mouseDown(with: event)
            _ = onDefinitionClick?(event.locationInWindow)
            return
        }
        if event.type == .leftMouseDown,
           event.modifierFlags.intersection([.command, .option, .shift, .control]) == .option {
            let existing = textLayoutManager.textSelections
            super.mouseDown(with: event)
            MultiCaretController.appendCaret(to: self, keeping: existing)
            return
        }
        let selBefore = textSelection
        super.mouseDown(with: event)
        ClickDebug.log("SnippetTextView.mouseDown loc=\(event.locationInWindow)"
            + " selBefore=\(selBefore) selAfter=\(textSelection)"
            + " marked=\(hasMarkedText())")
    }

    override func keyDown(with event: NSEvent) {
        if AppModel.shared.macroController.isRecording {
            AppModel.shared.macroController.record(event)
        }
        if event.keyCode == 49, // kVK_Space
           // Ignore .capsLock (part of deviceIndependentFlagsMask): Ctrl+Space must fire
           // with Caps Lock engaged too.
           event.modifierFlags.intersection([.command, .option, .shift, .control]) == .control,
           onCompletionTrigger?() == true {
            return
        }
        // Cmd+Opt+Left folds the region at the caret, Cmd+Opt+Right unfolds it. No text-editing
        // binding claims these chords, so intercepting here (rather than a menu item) keeps the
        // whole editor-key surface in one place — the same seam as Tab/Esc/Ctrl+Space.
        if event.modifierFlags.intersection([.command, .option, .shift, .control]) == [.command, .option],
           event.keyCode == 123 || event.keyCode == 124, // kVK_LeftArrow / kVK_RightArrow
           onFoldToggle?(event.keyCode == 123) == true {
            return
        }
        super.keyDown(with: event)
    }
}

/// Drives one live `SnippetSession` for a single editor. Owned by the hosting window view
/// (`@StateObject`) so it can also back the Insert Snippet menu via a focused value; the
/// editor's `Coordinator` sets `textView` and forwards key commands / buffer edits here.
@MainActor
final class SnippetController: ObservableObject {
    private let library: SnippetLibrary
    weak var textView: STTextView?
    private var session: SnippetSession?

    /// Re-entrancy guard. Set while this controller is mutating the buffer or selection
    /// itself (expansion insert, mirror-edit application, stop navigation) so the resulting
    /// delegate callbacks — including the mirror edits, which are already pre-accounted in
    /// `SnippetSession` — are never fed back into the session.
    private var isMutating = false

    /// Cheap probe for the editor's `willChangeTextIn`/`didChangeTextIn` hooks so they skip
    /// all range bookkeeping when no snippet is live (the overwhelmingly common case).
    var isSessionActive: Bool { session?.isActive == true }

    init(library: SnippetLibrary) {
        self.library = library
    }

    // MARK: - Key commands (forwarded from the editor Coordinator)

    /// No session: expand the trigger word before the caret, if any. Active session:
    /// advance to the next stop (always consumed — a Tab inside a snippet never inserts a
    /// literal tab; the final Tab lands the caret on `$0` and ends the session).
    func handleTab(textView: STTextView, languageID: String?) -> Bool {
        // With multiple carets active, Tab stays a literal tab across all of them (STTextView-native):
        // no trigger expansion, no session.
        if MultiCaretController.hasMultipleSelections(textView) { return false }
        if session != nil {
            advance(textView: textView)
            return true
        }
        guard let (range, snippet) = triggerMatch(textView: textView, languageID: languageID) else {
            return false
        }
        expand(snippet, replacing: range, textView: textView)
        return true
    }

    func handleShiftTab(textView: STTextView) -> Bool {
        guard let session else { return false }
        isMutating = true
        session.previous()
        selectCurrentStop(textView: textView)
        isMutating = false
        return true
    }

    func handleEscape(textView: STTextView) -> Bool {
        guard session != nil else { return false }
        session = nil
        return true
    }

    // MARK: - Buffer + caret feedback

    func textDidChange(range: NSRange, replacement: String, textView: STTextView) {
        guard !isMutating, let session, session.isActive else { return }
        let edits = session.bufferDidChange(range: range.lowerBound ..< range.upperBound, replacement: replacement)
        if !session.isActive { self.session = nil }
        guard !edits.isEmpty else { return }
        applyMirrorEdits(edits, textView: textView)
    }

    func caretDidMove(to offset: Int) {
        guard !isMutating, let session, session.isActive else { return }
        session.caretMoved(to: offset)
        if !session.isActive { self.session = nil }
    }

    // MARK: - Menu insertion

    /// Insert Snippet menu: expand at the caret (replacing any selection), same as Tab but
    /// with no trigger word to remove.
    func insert(_ snippet: Snippet) {
        guard let textView else { return }
        expand(snippet, replacing: textView.textSelection, textView: textView)
    }

    // MARK: - Completion popup seam (CompletionController merge source 4)

    /// Language-scoped snippet triggers usable as completion candidates: trigger
    /// case-insensitively starts with `prefix`, excluding an exact match (that candidate
    /// would just repeat what's already typed — same rule word sources use).
    func completionCandidates(prefix: String, languageID: String?) -> [Snippet] {
        guard !prefix.isEmpty else { return [] }
        let lowerPrefix = prefix.lowercased()
        return library.snippets(forLanguageID: languageID).filter {
            $0.trigger.lowercased().hasPrefix(lowerPrefix) && $0.trigger != prefix
        }
    }

    /// Accepts a snippet completion row: expands `snippet` in place of `range` (the
    /// completion popup's prefix range) via the same expansion core `handleTab`/`insert`
    /// use — one place turns a `Snippet` into buffer text and stop navigation.
    func acceptCompletion(_ snippet: Snippet, replacing range: NSRange, textView: STTextView) {
        expand(snippet, replacing: range, textView: textView)
    }

    // MARK: - Expansion core

    private func expand(_ snippet: Snippet, replacing range: NSRange, textView: STTextView) {
        guard let parsed = try? SnippetParser.parse(snippet.body) else { return }
        let session = SnippetSession(snippet: parsed, insertionOffset: range.location)

        isMutating = true
        textView.insertText(session.insertText, replacementRange: range)
        // Retain the session only if there is somewhere to navigate; a body that parses to
        // just `$0` leaves the caret placed with no session lingering to swallow the next Tab.
        self.session = Self.hasNavigableStops(parsed.nodes) ? session : nil
        selectCurrentStop(session: session, textView: textView)
        isMutating = false
    }

    private func advance(textView: STTextView) {
        guard let session else { return }
        isMutating = true
        session.next()
        selectCurrentStop(textView: textView)
        if !session.isActive { self.session = nil }
        isMutating = false
    }

    /// Selects the current stop's primary range (zero-width → caret placement).
    private func selectCurrentStop(textView: STTextView) {
        guard let session else { return }
        selectCurrentStop(session: session, textView: textView)
    }

    private func selectCurrentStop(session: SnippetSession, textView: STTextView) {
        guard let primary = session.currentStopRanges.first else { return }
        textView.textSelection = NSRange(location: primary.lowerBound, length: primary.count)
    }

    /// Mirror edits arrive sorted descending and in post-primary-edit absolute coordinates,
    /// so applying them in order against the already-updated buffer is correct.
    /// `replaceCharacters(in:with:)` (unlike `insertText`) leaves the selection untouched, so
    /// the caret stays where the user's keystroke left it in the primary stop.
    private func applyMirrorEdits(_ edits: [MirrorEdit], textView: STTextView) {
        isMutating = true
        for edit in edits {
            let ns = NSRange(location: edit.range.lowerBound, length: edit.range.count)
            guard let textRange = Self.textRange(ns, in: textView) else { continue }
            textView.replaceCharacters(in: textRange, with: edit.replacement)
        }
        isMutating = false
    }

    // MARK: - Trigger detection

    /// The `[A-Za-z0-9_]+` run ending at a plain caret, looked up in the library. All word
    /// characters are ASCII (single UTF-16 code units), so scanning code units is safe.
    private func triggerMatch(textView: STTextView, languageID: String?) -> (NSRange, Snippet)? {
        let selection = textView.textSelection
        guard selection.length == 0 else { return nil }
        let text = (textView.text ?? "") as NSString
        let caret = selection.location
        guard caret <= text.length else { return nil }

        var start = caret
        while start > 0, Self.isWordCharacter(text.character(at: start - 1)) {
            start -= 1
        }
        guard start < caret else { return nil }

        let word = text.substring(with: NSRange(location: start, length: caret - start))
        guard let snippet = library.snippet(trigger: word, languageID: languageID) else { return nil }
        return (NSRange(location: start, length: caret - start), snippet)
    }

    private static func isWordCharacter(_ c: unichar) -> Bool {
        (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
    }

    private static func hasNavigableStops(_ nodes: [SnippetNode]) -> Bool {
        nodes.contains { node in
            switch node {
            case .text:
                return false
            case .tabStop(let index, let placeholder):
                return index != 0 || hasNavigableStops(placeholder)
            }
        }
    }

    // MARK: - UTF-16 offset ⇄ TextKit 2 range (standard NSTextContentManager API only)

    static func nsRange(_ textRange: NSTextRange, in contentManager: NSTextContentManager) -> NSRange {
        let location = contentManager.offset(from: contentManager.documentRange.location, to: textRange.location)
        let length = contentManager.offset(from: textRange.location, to: textRange.endLocation)
        return NSRange(location: location, length: length)
    }

    private static func textRange(_ nsRange: NSRange, in textView: STTextView) -> NSTextRange? {
        let contentManager = textView.textContentManager
        guard let start = contentManager.location(contentManager.documentRange.location, offsetBy: nsRange.location),
              let end = contentManager.location(start, offsetBy: nsRange.length) else {
            return nil
        }
        return NSTextRange(location: start, end: end)
    }
}

// MARK: - Focused value for the Insert Snippet menu

/// The frontmost editor's language scope plus a closure that expands a chosen snippet at its
/// caret. Published via `focusedSceneValue` so the App-level Commands ▸ Insert Snippet menu
/// can target whichever editor is focused.
struct SnippetInsertion {
    let languageID: String?
    let insert: (Snippet) -> Void
}

private struct FocusedSnippetInsertionKey: FocusedValueKey {
    typealias Value = SnippetInsertion
}

extension FocusedValues {
    var snippetInsertion: SnippetInsertion? {
        get { self[FocusedSnippetInsertionKey.self] }
        set { self[FocusedSnippetInsertionKey.self] = newValue }
    }
}
