import SwiftUI
import AppKit
import MeatPadKit

/// A card's edit field when card line spacing is above 1×. SwiftUI's `TextField` takes neither
/// `.lineSpacing` nor `.lineHeight` on macOS and sizes from its own cell, so a spaced card face
/// closed up — and shrank — the moment it was clicked into. Owning the `NSTextField` gives the
/// field the face's paragraph style and the face's height. Still an AXTextField with a field
/// editor behind it, so the caret-follow, drag-type and caret-to-end seams keep working.
struct SpacedTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let font: NSFont
    let lineHeightMultiple: CGFloat
    /// 0 means no limit.
    var lineLimit: Int = 0
    let identifier: String
    /// Shift/Option+Return put a line break in; without this every Return submits.
    var newlineChords = false
    let isFocused: Bool
    var onSubmit: () -> Void = {}
    /// The field editor let go — a click elsewhere, Tab — so the owner can blur.
    var onEndEditing: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// The window's shared field editor is TextKit 2, which lays a spaced line out taller and
    /// wraps it at other points than the face's TextKit 1 `LinkLabel` — the card grew a line
    /// when clicked into. This cell hands its field an editor of its own, on TextKit 1, styled
    /// for this field alone; the shared one is never touched.
    final class Cell: NSTextFieldCell {
        var paragraph = NSParagraphStyle.default
        lazy var editor: NSTextView = {
            let editor = NSTextView(usingTextLayoutManager: false)
            editor.isFieldEditor = true
            editor.isRichText = false
            return editor
        }()

        override func fieldEditor(for controlView: NSView) -> NSTextView? { editor }

        // AppKit loads the editor's text itself, without the paragraph style — put it on after.
        override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
            super.edit(withFrame: rect, in: controlView, editor: textObj, delegate: delegate, event: event)
            style(textObj)
        }

        override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
            super.select(withFrame: rect, in: controlView, editor: textObj, delegate: delegate,
                         start: selStart, length: selLength)
            style(textObj)
        }

        func style(_ text: NSText) {
            guard let editor = text as? NSTextView, let storage = editor.textStorage else { return }
            editor.defaultParagraphStyle = paragraph
            editor.typingAttributes[.paragraphStyle] = paragraph
            if storage.length > 0 {
                storage.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: storage.length))
            }
        }
    }

    final class Field: NSTextField {
        override class var cellClass: AnyClass? {
            get { Cell.self }
            set {}
        }
    }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.isEditable = true
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.lineBreakMode = .byWordWrapping
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier(identifier)
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        // The editor takes its font from the cell, not from the attributed string.
        field.font = font
        field.maximumNumberOfLines = lineLimit
        field.placeholderAttributedString = attributed(placeholder, color: .placeholderTextColor)
        (field.cell as? Cell)?.paragraph = paragraph
        // Never while the editor holds the text: that resets the text and the caret.
        if field.currentEditor() == nil, field.stringValue != text {
            field.attributedStringValue = attributed(text, color: .labelColor)
        }
        if isFocused, field.currentEditor() == nil {
            // A turn later: the field is only in its window once this update has landed.
            DispatchQueue.main.async {
                guard let window = field.window, field.currentEditor() == nil else { return }
                window.makeFirstResponder(field)
            }
        }
    }

    /// Measured the way the face measures — a `LinkLabel` over the live text — so the card
    /// keeps its height when clicked into.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: Field, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? max(1, field.bounds.width)
        let measure = context.coordinator.measure
        measure.apply(attributed(text.isEmpty ? placeholder : text, color: .labelColor), links: [], lineLimit: lineLimit)
        return measure.size(fitting: width)
    }

    fileprivate var paragraph: NSParagraphStyle { LinkableText.paragraph(lineHeightMultiple) }

    private func attributed(_ string: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SpacedTextField
        let measure = LinkLabel()

        init(_ parent: SpacedTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            // A paste brings its text in without the paragraph style.
            if let editor = field.currentEditor() { (field.cell as? Cell)?.style(editor) }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onEndEditing()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:))
                || selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
                || selector == #selector(NSResponder.insertLineBreak(_:)) else { return false }
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if parent.newlineChords, ReturnKey.insertsNewline(shift: flags.contains(.shift), option: flags.contains(.option),
                                                              command: flags.contains(.command), control: flags.contains(.control)) {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent.onSubmit()
            }
            return true
        }
    }
}
