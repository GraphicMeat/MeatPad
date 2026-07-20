import AppKit
import Foundation
import LanguageServerProtocol
import MeatPadKit

/// Go to Definition (0.7 LSP plan Task 4): the multiple-locations picker. Response
/// normalization (`GoToDefinition.locations(from:)`) lives in MeatPadKit — pure, no AppKit
/// needed; this extension adds the AppKit-dependent picker onto that same type. Deliberately
/// NOT folded into `LSPController` — that type is scoped to one editor instance's
/// diagnostics/hover state (`attach(to:)` binds it to a single `STTextView`), while
/// navigating a definition result can open a *different* editor tab or even a new project
/// window. That's `ProjectViewModel.goToDefinition` territory, so this file only holds the
/// UI glue both the picker and the caller share.
extension GoToDefinition {
    /// Multiple-locations popup per the plan ("Multiple locations → NSMenu popup at
    /// caret/click point listing file:line entries, pick → navigate"). `screenPoint` is
    /// screen coordinates — `NSMenu.popUp(in:)` reads `at:` that way when `in:` is `nil`.
    /// Blocks on AppKit's own menu-tracking loop until dismissed or a row is picked; the
    /// `target` local is what keeps `NSMenuItem.target` (a weak reference) alive for that
    /// whole call.
    @MainActor
    static func presentPicker(locations: [Location], at screenPoint: NSPoint, onPick: @escaping (Location) -> Void) {
        let menu = NSMenu()
        let target = PickerTarget(onPick: onPick)
        for location in locations {
            let url = URL(string: location.uri)
            let item = NSMenuItem(
                title: "\(url?.lastPathComponent ?? location.uri):\(location.range.start.line + 1)",
                action: #selector(PickerTarget.pick(_:)),
                keyEquivalent: ""
            )
            item.target = target
            item.representedObject = location
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: screenPoint, in: nil)
    }

    private final class PickerTarget: NSObject {
        let onPick: (Location) -> Void
        init(onPick: @escaping (Location) -> Void) { self.onPick = onPick }
        @objc func pick(_ sender: NSMenuItem) {
            guard let location = sender.representedObject as? Location else { return }
            onPick(location)
        }
    }
}
