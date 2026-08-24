import Foundation

/// What Return means in a field that both commits and holds more than one line — a board's
/// add-card field, a card's notes. AppKit's field editor answers this itself in an
/// NSTextView, but SwiftUI's `TextField` never gets that far: Return submits and the
/// modified chords do nothing, so the app decides.
public enum ReturnKey {

    /// Shift+Return and Option+Return insert a line break; bare Return still submits, and a
    /// Command/Control chord belongs to whatever shortcut owns it.
    public static func insertsNewline(shift: Bool, option: Bool, command: Bool, control: Bool) -> Bool {
        guard !command, !control else { return false }
        return shift || option
    }
}
