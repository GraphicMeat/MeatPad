import SwiftUI
import AppKit

/// How a note's editor hands a link over: the modifier Xcode uses, or a plain click the way
/// Notes does it. Cards are always a plain click — a card face is a reading surface until it
/// is clicked, so there is nothing for a modifier to protect.
enum LinkActivation: String, CaseIterable, Identifiable {
    case command
    case click

    var id: String { rawValue }

    var label: String {
        switch self {
        case .command: String(localized: "⌘-click")
        case .click: String(localized: "Click")
        }
    }
}

/// The single place a detected link is opened. Everything routes through here so a UI test
/// can launch with `-meatpad.suppressLinkOpen YES` and click a link without the machine
/// changing hands to Safari.
enum LinkOpener {
    static func open(_ url: URL) {
        guard !UserDefaults.standard.bool(forKey: "meatpad.suppressLinkOpen") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// One note surface's link-paste hint. A small object rather than `@State` so the editor's
/// paste callback — handed down into an `NSViewRepresentable` — can raise it without
/// capturing a view value that has since been rebuilt.
@MainActor
final class LinkPasteHintState: ObservableObject {
    static let suppressedKey = "linkPasteHint.suppressed"

    @Published fileprivate var shown = false
    /// The countdown to taking the hint away again. Owned here rather than run as a
    /// `.task(id:)` on the view: the editor rebuilds constantly while the user types, and a
    /// dismissal that a rebuild can cancel is a hint that stays on screen forever.
    private var dismissal: Task<Void, Never>?

    func pasted() {
        guard !UserDefaults.standard.bool(forKey: Self.suppressedKey) else { return }
        withAnimation(.snappy(duration: 0.2)) { shown = true }
        // A second paste gets the full eight seconds, not the tail of the first one's.
        dismissal?.cancel()
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    fileprivate func dismiss() {
        dismissal?.cancel()
        withAnimation(.snappy(duration: 0.2)) { shown = false }
    }
}

extension View {
    /// Shows `state`'s hint over the top edge of this view, and takes it away again after
    /// eight seconds — it is a note, not a decision to make.
    func linkPasteHint(_ state: LinkPasteHintState) -> some View {
        modifier(LinkPasteHintModifier(state: state))
    }
}

private struct LinkPasteHintModifier: ViewModifier {
    @ObservedObject var state: LinkPasteHintState
    @EnvironmentObject private var appModel: AppModel
    @AppStorage(LinkPasteHintState.suppressedKey) private var suppressed = false

    func body(content: Content) -> some View {
        content
            // Over the text, never above it: the hint answers a question the user hasn't
            // asked, so it must not shove the line they just pasted down the window.
            .overlay(alignment: .top) {
                if state.shown {
                    LinkPasteHint(
                        activation: appModel.linkActivation,
                        suppressed: $suppressed,
                        onDismiss: state.dismiss
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            // Ticking the checkbox is also a dismissal — the hint has had its say.
            .onChange(of: suppressed) { _, now in if now { state.dismiss() } }
    }
}

/// The one-line hint shown at the top of a note window after a link is pasted, saying what
/// opens it and where to change that. Floats over the text rather than pushing it down: it
/// answers a question the user hasn't asked yet, so it must not move what they're reading.
struct LinkPasteHint: View {
    let activation: LinkActivation
    /// Set from the hint's own checkbox — the caller owns the default it writes to.
    @Binding var suppressed: Bool
    let onDismiss: () -> Void

    @EnvironmentObject private var appModel: AppModel
    @Environment(\.openSettings) private var openSettings

    private var message: String {
        switch activation {
        case .command: String(localized: "Links open with ⌘-click.")
        case .click: String(localized: "Links open with a click.")
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .foregroundStyle(MeatPadGlass.tint.gradient)
            Text(message)
                .font(.callout)
                // The identifier lives on the message, not on the row: an identifier on the
                // container clobbers every child's, and the Settings button needs its own.
                .accessibilityIdentifier("linkHint")
            Button("Settings…") {
                appModel.settingsTab = .general
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.link)
            .accessibilityIdentifier("linkHint.settings")
            Toggle("Don’t Show Again", isOn: $suppressed)
                .toggleStyle(.checkbox)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Dismiss"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassPanel(cornerRadius: 12, shadow: true)
        .padding(.top, 10)
    }
}
