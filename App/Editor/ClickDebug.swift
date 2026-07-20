import AppKit

/// Round-3 click-caret instrumentation (DEBUG builds only; no-op in release).
/// Logs every leftMouseDown's routing context to stderr AND to
/// meatpad-clickdebug.log in the app container's tmp dir, so a manual repro can
/// show exactly where a click dies:
///  - no LOCAL-DOWN line          → event never reached the app's local monitor
///                                  (activation / window-level issue)
///  - LOCAL-DOWN, no SnippetTextView.mouseDown line
///                                → consumed between window and text view (the
///                                  logged hit view names the thief)
///  - mouseDown with selBefore == selAfter
///                                → swallowed inside STTextView (prime suspect:
///                                  its inputContext?.handleEvent guard)
///  - EditorClipView line for an on-text click
///                                → window hit-testing resolved text to the clip
///                                  view (text view frame doesn't cover the text)
enum ClickDebug {
    #if DEBUG
    private static let logURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("meatpad-clickdebug.log")

    /// Installed once from applicationDidFinishLaunching. The monitor observes and
    /// always returns the event unmodified — zero behavior change.
    static func install() {
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            let window = event.window
            let app = NSApplication.shared
            let hit = window?.contentView?.hitTest(
                window?.contentView?.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
            )
            var hitChain = [String]()
            var v: NSView? = hit
            while let cur = v { hitChain.append(String(describing: type(of: cur))); v = cur.superview }
            log("LOCAL-DOWN loc=\(event.locationInWindow)"
                + " appActive=\(app.isActive)"
                + " window=\(window.map { String(describing: type(of: $0)) } ?? "nil")"
                + " isKey=\(window?.isKeyWindow ?? false)"
                + " firstResponder=\(window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")"
                + " hitChain=\(hitChain.joined(separator: "<"))")
            return event
        }
        log("=== ClickDebug installed \(Date()) — log at \(logURL.path) ===")
    }

    static func log(_ message: String) {
        let line = "[clickdebug \(String(format: "%.3f", Date().timeIntervalSince1970))] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }
    #else
    @inline(__always) static func install() {}
    @inline(__always) static func log(_ message: @autoclosure () -> String) {}
    #endif
}
