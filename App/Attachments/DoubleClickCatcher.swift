import SwiftUI
import AppKit
import os

/// Quick Look's double-click path, logged end to end: whether the double-click reached the
/// monitor, whether it found a tile, which file `AttachmentStrip` asked to preview, and whether
/// the panel was up half a second later. This round of "double-click doesn't always open
/// Quick Look" was found by exactly these lines (see `QuickLookHost`), so they stay for the
/// next miss:
///   log stream --level debug --predicate 'subsystem == "com.thecoldzero.MeatPad" && category == "quicklook"'
/// No double-click line = the second click never counted as one; a line with no tile = the
/// hit test landed elsewhere (the class says where); an open with "panel NOT up" = the
/// presentation side.
let quickLookLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.thecoldzero.MeatPad", category: "quicklook")

/// "Double-click me" as an AppKit view rather than a `TapGesture(count: 2)`. A SwiftUI
/// double-tap on an attachment tile loses to whatever else is watching the row — the card's
/// `.draggable`, the board's own double-click monitor — because those all see the first
/// click first. The tile takes the gesture from a local event monitor instead, and forwards
/// everything that is not a double-click, so single clicks, drags and the context menu are
/// untouched.
struct DoubleClickCatcher: NSViewRepresentable {
    /// The catcher IS the accessibility element for what it covers: an NSView on top of a
    /// SwiftUI element leaves that element "not hittable" (VoiceOver and XCUITest both
    /// hit-test to the view), whether the view is ignored or not — so it carries the label
    /// and identifier itself and answers a press with the same action as a double-click.
    let identifier: String
    let label: String
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> DoubleClickCatcherView {
        DoubleClickCatcherView.installMonitor()
        let view = DoubleClickCatcherView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        update(view)
        return view
    }

    func updateNSView(_ view: DoubleClickCatcherView, context: Context) { update(view) }

    private func update(_ view: DoubleClickCatcherView) {
        view.onDoubleClick = onDoubleClick
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel(label)
    }
}

final class DoubleClickCatcherView: NSView {
    var onDoubleClick: () -> Void = {}

    /// The window need not be key first: a tile in a background window opens on one gesture.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityPerformPress() -> Bool { onDoubleClick(); return true }

    /// `.contextMenu` is SwiftUI's, one responder up — pass the right-click along, and answer
    /// the menu lookup with the view underneath, or the tile loses its menu to this overlay.
    override func rightMouseDown(with event: NSEvent) {
        nextResponder?.rightMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? { superview?.menu(for: event) }

    /// The gesture arrives through a monitor rather than this view's own `mouseDown`: a
    /// monitor sees every left mouse-down the app dispatches, while a nested AppKit view only
    /// sees the ones SwiftUI's gesture recognisers (the card's drag, the row's tap, the
    /// overlay's ScrollView) have not already claimed for themselves. One monitor for the
    /// process — every tile in every window reads from it — installed with the first tile and
    /// kept for the app's life: there is no moment where the app has no tiles and cares.
    private static var monitor: Any?

    static func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard event.clickCount == 2 else { return event }
            guard let catcher = catcher(for: event) else {
                let hit = event.window?.contentView?.hitTest(event.locationInWindow)
                let hitClass = hit.map { String(describing: type(of: $0)) } ?? "nil"
                let windowClass = event.window.map { String(describing: type(of: $0)) } ?? "nil"
                let point = "\(event.locationInWindow)"
                quickLookLog.debug("double-click, no tile: hit \(hitClass, privacy: .public) in \(windowClass, privacy: .public) at \(point, privacy: .public)")
                return event
            }
            quickLookLog.debug("double-click on a tile")
            catcher.onDoubleClick()
            // Swallowed: the double-click belongs to the tile, and the row underneath must not
            // also act on it.
            return nil
        }
    }

    /// The tile under an event, if the click landed on one. The board's own double-click
    /// monitor asks this too — presenting a card must not fight Quick Look.
    static func catcher(for event: NSEvent) -> DoubleClickCatcherView? {
        var view = event.window?.contentView?.hitTest(event.locationInWindow)
        while let current = view {
            if let catcher = current as? DoubleClickCatcherView { return catcher }
            view = current.superview
        }
        return nil
    }
}
