import AppKit
import SwiftTerm

/// SwiftTerm's local-process terminal, with two MeatPad additions: it is one accessibility
/// text area whose value is the active buffer's text, scrollback included (VoiceOver and the UI
/// tests read it), and after the shell exits it swallows input until ⏎, which asks the
/// controller for a fresh shell.
final class MeatPadTerminalView: LocalProcessTerminalView {
    /// Set by `ProjectTerminalController` when the shell is gone; `nil` while it runs.
    var exitCode: Int32?
    var onRestartRequested: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel(String(localized: "Terminal"))
        setAccessibilityIdentifier("project-terminal")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The whole active buffer as text, scrollback included, one line per row. Read on the main
    /// thread by accessibility clients; never called from a terminal delegate callback.
    override func accessibilityValue() -> Any? {
        String(decoding: getTerminal().getBufferAsData(kind: .active), as: UTF8.self)
    }

    /// Every keystroke the terminal wants to send to the process passes through here
    /// (`TerminalViewDelegate.send`). With the shell gone there is nobody to send to: ⏎ (0x0D)
    /// restarts, everything else is dropped.
    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if exitCode != nil {
            if data.contains(0x0D) { onRestartRequested?() }
            return
        }
        super.send(source: source, data: data)
    }
}
