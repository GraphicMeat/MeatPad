import AppKit
import MeatPadKit

/// Cmd+P: prints the focused editor's document as plain monospaced text on paper.
///
/// Renders into a fresh, off-screen `NSTextView` (AppKit's classic print pipeline —
/// NOT the STTextView editor instance itself) so the print job is independent of
/// on-screen scroll/selection state. Colors are forced to the light theme regardless
/// of the app's current theme, since printed paper is always light. Syntax-colored
/// printing is not required by spec, so this renders plain foreground text only.
enum PrintController {
    @MainActor
    static func print(context: EditorCommandContext) {
        let printInfo = NSPrintInfo.shared
        let width = printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        textView.isEditable = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)

        let theme = BuiltinThemes.defaultLight
        textView.string = context.documentText()
        textView.font = CodeEditor.font(size: 13)
        textView.textColor = NSColor(theme.editorForeground)
        // ponytail: no background fill — plain white paper, not the editor's painted bg.
        textView.drawsBackground = false

        let printOperation = NSPrintOperation(view: textView, printInfo: printInfo)
        printOperation.jobTitle = context.displayName
        printOperation.showsPrintPanel = true

        if let window = NSApp.keyWindow {
            printOperation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            printOperation.run()
        }
    }
}
