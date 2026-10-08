import AppKit
import MeatPadKit
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

    private var scrollMonitor: Any?
    private var scroll = TerminalScrollAccumulator()

    deinit { if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) } }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor); self.scrollMonitor = nil }
        if window != nil {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handleScroll(event) ?? event
            }
        }
        // Never inside AppKit's mount (or the SwiftUI pass that triggered it): one turn later.
        DispatchQueue.main.async { [weak self] in self?.claimFocusIfWanted() }
    }

    /// SwiftTerm's own `scrollWheel` is not overridable and truncates every fractional trackpad
    /// delta to a whole line per event, so a swipe flies past. This monitor takes the events that
    /// land on the terminal and scrolls by accumulated whole lines: the scrollback on the normal
    /// screen; on the alternate screen (less, vim, TUIs) wheel reports when the app asked for
    /// the mouse, cursor keys otherwise.
    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window,
              window.contentView?.hitTest(event.locationInWindow)?.isDescendant(of: self) == true
        else { return event }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) { scroll.reset() }
        let terminal = getTerminal()
        let precise = event.hasPreciseScrollingDeltas
        let lines = precise
            ? scroll.lines(delta: Double(event.scrollingDeltaY), unit: Double(bounds.height) / Double(max(terminal.rows, 1)))
            : scroll.lines(delta: Double(event.deltaY) * 3, unit: 1)
        guard lines != 0 else { return nil }
        let up = lines > 0
        let count = abs(lines)
        if !terminal.isCurrentBufferAlternate {
            if up { scrollUp(lines: count) } else { scrollDown(lines: count) }
        } else if allowMouseReporting && terminal.mouseMode != .off {
            let point = convert(event.locationInWindow, from: nil)
            let col = min(max(Int(point.x / (bounds.width / Double(max(terminal.cols, 1)))), 0), terminal.cols - 1)
            let row = min(max(Int((bounds.height - point.y) / (bounds.height / Double(max(terminal.rows, 1)))), 0), terminal.rows - 1)
            for _ in 0..<min(count, 20) {
                terminal.sendEvent(buttonFlags: up ? 64 : 65, x: col, y: row, pixelX: Int(point.x), pixelY: Int(bounds.height - point.y))
            }
        } else {
            let key = terminal.applicationCursor ? (up ? "\u{1b}OA" : "\u{1b}OB") : (up ? "\u{1b}[A" : "\u{1b}[B")
            send(txt: String(repeating: key, count: min(count, 20)))
        }
        return nil
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
