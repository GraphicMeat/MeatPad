import Foundation

/// ⇧⏎ in the terminal panel. SwiftTerm resolves it to `insertNewline` and sends a bare CR, the
/// same as ⏎, so a program cannot tell it from "run". VS Code's terminal binds it to ESC + CR,
/// which Claude Code and other TUIs read as "insert a newline"; MeatPad sends the same.
public enum TerminalSoftNewline {
    public static let sequence: [UInt8] = [0x1B, 0x0D]

    private static let returnKeyCode: UInt16 = 36
    private static let keypadEnterKeyCode: UInt16 = 76

    /// - Parameters:
    ///   - shift: ⇧ is held.
    ///   - otherModifiers: ⌃, ⌥ or ⌘ is held; those chords keep their own handling.
    public static func matches(keyCode: UInt16, shift: Bool, otherModifiers: Bool) -> Bool {
        shift && !otherModifiers && (keyCode == returnKeyCode || keyCode == keypadEnterKeyCode)
    }
}
