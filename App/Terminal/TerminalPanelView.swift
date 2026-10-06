import SwiftUI
import AppKit
import MeatPadKit

/// Bottom pane of a project window: a header (title, working directory, restart, close), a
/// drag handle on its top edge, and the terminal itself at the remembered height.
struct TerminalPanelView: View {
    @ObservedObject var project: ProjectViewModel
    @ObservedObject var controller: ProjectTerminalController
    @ObservedObject private var appModel = AppModel.shared
    @ObservedObject private var zoom = ProjectZoom.shared
    @AppStorage(TerminalPanelHeight.defaultsKey) private var panelHeight = TerminalPanelHeight.default
    @State private var dragStartHeight: Double?

    var body: some View {
        VStack(spacing: 0) {
            header
            TerminalHostView(
                controller: controller,
                theme: appModel.theme,
                fontSize: appModel.fontSize * CGFloat(zoom.scale),
                focusToken: project.terminalFocusToken
            )
            .frame(height: CGFloat(panelHeight))
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().opacity(0.45) }
        .overlay(alignment: .top) { dragHandle }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal.fill")
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
            Button(action: { project.hideTerminal() }) { Image(systemName: "xmark") }
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
                if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if dragStartHeight == nil { dragStartHeight = panelHeight }
                        let proposed = (dragStartHeight ?? panelHeight) - Double(value.translation.height)
                        let windowHeight = Double(project.window?.frame.height ?? 800)
                        panelHeight = TerminalPanelHeight.clamp(proposed, windowHeight: windowHeight)
                    }
                    .onEnded { _ in dragStartHeight = nil }
            )
    }
}
