import Foundation

/// The terminal panel's height rules: a floor so the prompt stays usable, and a ceiling that
/// leaves the editor above it a usable strip. Persisted app-wide under `defaultsKey`.
public enum TerminalPanelHeight {
    public static let defaultsKey = "terminal.panelHeight"
    public static let `default`: Double = 220
    public static let minimum: Double = 96
    /// Points the editor keeps however far the panel is dragged up.
    public static let editorReserve: Double = 160

    public static func clamp(_ proposed: Double, windowHeight: Double) -> Double {
        let ceiling = max(minimum, windowHeight - editorReserve)
        return min(max(proposed, minimum), ceiling)
    }
}
