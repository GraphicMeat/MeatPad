import SwiftUI
import AppKit

/// "Double-click me" as an AppKit view rather than a `TapGesture(count: 2)`. A SwiftUI
/// double-tap on an attachment tile loses to whatever else is watching the row — the card's
/// `.draggable`, the board's own double-click monitor — because those all see the first
/// click first. An NSView takes the mouse-down itself and forwards everything that is not a
/// double-click, so single clicks, drags and the context menu are untouched.
struct DoubleClickCatcher: NSViewRepresentable {
    /// The catcher IS the accessibility element for what it covers: an NSView on top of a
    /// SwiftUI element leaves that element "not hittable" (VoiceOver and XCUITest both
    /// hit-test to the view), whether the view is ignored or not — so it carries the label
    /// and identifier itself and answers a press with the same action as a double-click.
    let identifier: String
    let label: String
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> DoubleClickCatcherView {
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

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick() } else { super.mouseDown(with: event) }
    }

    /// `.contextMenu` is SwiftUI's, one responder up — pass the right-click along, and answer
    /// the menu lookup with the view underneath, or the tile loses its menu to this overlay.
    override func rightMouseDown(with event: NSEvent) {
        nextResponder?.rightMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? { superview?.menu(for: event) }
}
