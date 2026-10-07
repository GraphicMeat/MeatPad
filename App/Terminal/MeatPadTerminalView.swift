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
    /// A focus request that has not landed yet. `TerminalHostView` arms it when the view model
    /// asks for focus; it stays armed until `makeFirstResponder` succeeds. The claim itself is
    /// always deferred one run-loop turn (never inside SwiftUI's update or AppKit's mount), and
    /// the armed flag is what guarantees it eventually lands: a request made while the view is
    /// still being mounted (no window yet) is claimed by the turn queued from
    /// `viewDidMoveToWindow`. `ProjectViewModel.hideTerminal()` disarms it.
    var wantsFocus = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel(String(localized: "Terminal"))
        setAccessibilityIdentifier("project-terminal")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Never inside AppKit's mount (or the SwiftUI pass that triggered it): one turn later.
        DispatchQueue.main.async { [weak self] in self?.claimFocusIfWanted() }
    }

    /// Takes focus if a request is pending and the view is in a window; the request is
    /// cleared only once the window actually made this view first responder. Callers always
    /// invoke it one run-loop turn after the trigger, never from inside a SwiftUI update or an
    /// AppKit mount; `wantsFocus` staying armed is what guarantees a missed claim is retried.
    func claimFocusIfWanted() {
        guard wantsFocus, let window else { return }
        if window.makeFirstResponder(self) { wantsFocus = false }
    }

    /// SwiftUI sets the frame to 0×0 when it unmounts the view (the panel is hidden) and again
    /// before the first layout. SwiftTerm resizes its grid on every frame change, so a 0×0 frame
    /// shrinks it to 2×1 and truncates every line: the scrollback would not survive hide/show.
    /// An empty frame is ignored; the view keeps its last real size until SwiftUI lays it out
    /// again at the panel's size.
    override func setFrameSize(_ newSize: NSSize) {
        guard newSize.width >= 1, newSize.height >= 1 else { return }
        super.setFrameSize(newSize)
    }

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
