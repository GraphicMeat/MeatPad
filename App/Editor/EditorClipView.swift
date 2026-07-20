import AppKit
import STTextView

/// The editor scroll view's clip view. A mouseDown reaches the clip view only when
/// the click landed on no subview — i.e. in the dead space below a short document
/// (STTextView's frame only spans its content). Treat that as "click at end of
/// document": focus the editor, caret to the end — for an empty note that's the
/// first line. Clicks on text hit the text view subtree and never arrive here, so
/// this needs no dead-space-vs-text guard at all, and — unlike the previous
/// NSClickGestureRecognizer approach — adds nothing to the event path of normal
/// clicks.
final class EditorClipView: NSClipView {
    override func mouseDown(with event: NSEvent) {
        guard let textView = documentView as? STTextView else {
            super.mouseDown(with: event)
            return
        }
        ClickDebug.log("EditorClipView.mouseDown dead-space click at \(event.locationInWindow)")
        window?.makeFirstResponder(textView)
        textView.textSelection = NSRange(location: (textView.text as NSString? ?? "").length, length: 0)
    }
}
