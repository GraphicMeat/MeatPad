import SwiftUI
import AppKit
import MeatPadKit

/// Bottom pane of a project window: a header (title, working directory, restart, close), a
/// drag handle on its top edge, and the terminal itself at the remembered height.
struct TerminalPanelView: View {
    @ObservedObject var project: ProjectViewModel
    @ObservedObject var controller: ProjectTerminalController
    /// Height of the whole detail area the panel sits in (measured by `ProjectWindow`'s
    /// GeometryReader); the panel never grows past it minus the editor's reserve.
    let containerHeight: CGFloat
    @ObservedObject private var appModel = AppModel.shared
    @ObservedObject private var zoom = ProjectZoom.shared
    @AppStorage(TerminalPanelHeight.defaultsKey) private var panelHeight = TerminalPanelHeight.default
    /// The height when the current drag began; a GestureState, so it also resets when the drag is cancelled.
    @GestureState private var dragStartHeight: Double?
    @State private var cursorPushed = false

    /// The stored height as shown: it may be taller than fits after the window shrank or the
    /// setting came from a bigger window.
    private var shownHeight: Double {
        TerminalPanelHeight.clamp(panelHeight, windowHeight: Double(containerHeight))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            TerminalHostView(
                controller: controller,
                theme: appModel.theme,
                fontSize: appModel.fontSize * CGFloat(zoom.scale),
                focusToken: project.terminalFocusToken
            )
            .frame(height: CGFloat(shownHeight))
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().opacity(0.45) }
        .overlay(alignment: .top) { dragHandle }
        .onDisappear {
            if cursorPushed {
                NSCursor.pop()
                cursorPushed = false
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal.fill")
                .zoomFont(.body)
                .foregroundStyle(MeatPadGlass.violet.gradient)
            Text(controller.title ?? String(localized: "Terminal"))
                .zoomFont(.caption, weight: .bold)
                .lineLimit(1)
            if let directory = controller.currentDirectory {
                Text((directory as NSString).abbreviatingWithTildeInPath)
                    .zoomFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            if controller.exitCode != nil {
                Button(String(localized: "Restart")) { controller.restart() }
                    .zoomFont(.caption)
                    .accessibilityIdentifier("project-terminal-restart")
            }
            Button(action: { project.hideTerminal() }) { Image(systemName: "xmark").zoomFont(.body) }
                .help(String(localized: "Hide terminal"))
                .accessibilityIdentifier("project-terminal-close")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// A 7 pt strip over the panel's top edge. Dragging up grows the panel (negative translation).
    private var dragHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 7)
            .contentShape(Rectangle())
            .onHover { hovering in
                // Balanced push/pop: a hover that ends while the view goes away must not leave
                // the resize cursor on the stack.
                if hovering, !cursorPushed {
                    NSCursor.resizeUpDown.push()
                    cursorPushed = true
                } else if !hovering, cursorPushed {
                    NSCursor.pop()
                    cursorPushed = false
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .updating($dragStartHeight) { _, start, _ in
                        if start == nil { start = shownHeight }
                    }
                    .onChanged { value in
                        // The first event can arrive before the gesture state is committed; the
                        // panel has not moved yet then, so the shown height is the start.
                        let start = dragStartHeight ?? shownHeight
                        let proposed = start - Double(value.translation.height)
                        panelHeight = TerminalPanelHeight.clamp(proposed, windowHeight: Double(containerHeight))
                    }
            )
    }
}
