import AppKit

/// Keeps the caret of the focused text field in view while a card's notes grow.
///
/// A card's notes field has no height limit (a capped field would clip its text and eat the
/// scroll wheel), so typing past the bottom of the column pushes the caret off-screen and the
/// column doesn't follow. The field editor — the window's one shared `NSTextView` — is no help:
/// `scrollRangeToVisible` on it only scrolls the field's own private clip view and stops there.
/// `NSView.scrollToVisible` on the owning field instead walks up through every enclosing clip
/// view, up to the column's `ScrollView`, and only moves one when the rect really is off-screen
/// — so a card that is already fully visible never jumps.
@MainActor
enum FieldEditorScroll {
    /// Call from a field's `onChange`. Runs on the next turn: first responder and the grown
    /// layout are only current once the change that triggered this has been laid out, and
    /// once more shortly after, for SwiftUI's own pass that grows the card around the field.
    static func revealCaret() {
        DispatchQueue.main.async { scrollCaretIntoView() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { scrollCaretIntoView() }
    }

    private static func scrollCaretIntoView() {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
              let field = editor.delegate as? NSView,
              let layout = editor.layoutManager,
              let container = editor.textContainer else { return }
        layout.ensureLayout(for: container)

        let length = (editor.string as NSString).length
        let location = min(editor.selectedRange().location, length)
        var line: NSRect
        if location >= length, !layout.extraLineFragmentRect.isEmpty {
            // A caret after a trailing newline sits on the "extra" line, which has no glyph.
            line = layout.extraLineFragmentRect
        } else if layout.numberOfGlyphs > 0 {
            let glyph = min(layout.glyphIndexForCharacter(at: location), layout.numberOfGlyphs - 1)
            line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        } else {
            return
        }
        line.origin.x += editor.textContainerOrigin.x
        line.origin.y += editor.textContainerOrigin.y

        // A margin under the line, so the caret isn't left flush against the column's edge.
        let rect = field.convert(line, from: editor).insetBy(dx: 0, dy: -12)
        field.scrollToVisible(rect)
    }
}
