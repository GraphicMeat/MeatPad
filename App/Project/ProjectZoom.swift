import SwiftUI
import AppKit
import MeatPadKit

/// The project windows' ⌘+ / ⌘− zoom level, shared by every project window and remembered
/// across launches (a browser's per-app zoom, not per-window).
@MainActor
final class ProjectZoom: ObservableObject {
    static let shared = ProjectZoom()
    static let defaultsKey = "project.uiScale"

    @Published private(set) var scale: Double

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `double(forKey:)` rather than a cast: a launch argument arrives as a string.
        scale = defaults.object(forKey: Self.defaultsKey) == nil
            ? UIScale.actualSize
            : UIScale.sanitized(defaults.double(forKey: Self.defaultsKey))
    }

    func zoomIn() { set(UIScale.zoomedIn(from: scale)) }
    func zoomOut() { set(UIScale.zoomedOut(from: scale)) }
    func reset() { set(UIScale.actualSize) }

    private func set(_ new: Double) {
        guard new != scale else { return }
        scale = new
        defaults.set(new, forKey: Self.defaultsKey)
    }
}

/// The zoom shortcuts, handled before the responder chain so they work whatever has focus.
/// A focused text view is offered ⌘= (and friends) ahead of the menu bar and can swallow it, and
/// ⌘+ typed the way a Mac keyboard types it — ⌘⇧= — doesn't match the menu's ⌘= at all (the shift
/// changes the modifier mask). The menu items stay, for discoverability and mouse use.
/// Project windows only.
enum ProjectZoomShortcuts {
    @MainActor private static var monitor: Any?

    @MainActor static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard AppModel.shared.isProjectWindow(NSApp.keyWindow),
                  let key = event.charactersIgnoringModifiers else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch (modifiers, key) {
            case ([.command], "="), ([.command, .shift], "+"), ([.command, .shift], "="):
                ProjectZoom.shared.zoomIn()
            case ([.command], "-"):
                ProjectZoom.shared.zoomOut()
            case ([.command], "0"):
                ProjectZoom.shared.reset()
            default:
                return event
            }
            return nil
        }
    }
}

// MARK: - Applying the zoom

private struct ProjectZoomKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// The project window's zoom factor (1 = actual size). Set once at the root of
    /// `ProjectWindow`; views multiply their own fonts and fixed sizes by it.
    var projectZoom: CGFloat {
        get { self[ProjectZoomKey.self] }
        set { self[ProjectZoomKey.self] = newValue }
    }
}

/// macOS point sizes of the system text styles, so a style can be scaled like a fixed size.
private extension Font.TextStyle {
    var baseSize: CGFloat {
        switch self {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline, .body: 13
        case .callout: 12
        case .subheadline: 11
        case .footnote, .caption, .caption2: 10
        @unknown default: 13
        }
    }
    var defaultWeight: Font.Weight { self == .headline ? .semibold : .regular }
}

private struct ZoomFont: ViewModifier {
    @Environment(\.projectZoom) private var zoom
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    let monospacedDigit: Bool

    func body(content: Content) -> some View {
        let font = Font.system(size: size * zoom, weight: weight, design: design)
        content.font(monospacedDigit ? font.monospacedDigit() : font)
    }
}

extension View {
    /// `.font(.system(size:…))` that follows the project window's zoom.
    func zoomFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default,
                  monospacedDigit: Bool = false) -> some View {
        modifier(ZoomFont(size: size, weight: weight, design: design, monospacedDigit: monospacedDigit))
    }

    /// `.font(.callout…)` that follows the project window's zoom.
    func zoomFont(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design = .default,
                  monospacedDigit: Bool = false) -> some View {
        modifier(ZoomFont(size: style.baseSize, weight: weight ?? style.defaultWeight, design: design,
                          monospacedDigit: monospacedDigit))
    }
}
