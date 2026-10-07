import SwiftUI
import AppKit
import MeatPadKit

/// Mounts the controller's terminal NSView. The NSView outlives this representable (the
/// controller owns it), so hide/show re-mounts the same view with its process and scrollback.
/// Only ever placed in a concretely sized container (the panel's `.frame(height:)`), same rule
/// as `CodeEditor`.
struct TerminalHostView: NSViewRepresentable {
    @ObservedObject var controller: ProjectTerminalController
    let theme: Theme
    let fontSize: CGFloat
    /// Changes when the view model wants the terminal focused; see `ProjectViewModel.terminalFocusToken`.
    let focusToken: UUID?

    func makeNSView(context: Context) -> MeatPadTerminalView {
        controller.applyAppearance(theme: theme, fontSize: fontSize)
        controller.startIfNeeded()
        return controller.view
    }

    func updateNSView(_ view: MeatPadTerminalView, context: Context) {
        controller.applyAppearance(theme: theme, fontSize: fontSize)
        guard context.coordinator.lastFocusToken != focusToken else { return }
        context.coordinator.lastFocusToken = focusToken
        guard focusToken != nil else { return }
        // Armed until it lands, and claimed only one run-loop turn later, never inside this
        // update pass: next turn if the view is already in the window (after a mount or a
        // closing menu settles), else the turn queued by `viewDidMoveToWindow` once it arrives.
        // The armed flag is what guarantees the claim eventually lands.
        view.wantsFocus = true
        DispatchQueue.main.async {
            view.claimFocusIfWanted()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MeatPadTerminalView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastFocusToken: UUID?
    }
}
