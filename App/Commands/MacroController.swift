import AppKit
import MeatPadKit
import STTextView

/// Records raw key events while `isRecording` and replays a recorded sequence by
/// re-synthesizing `NSEvent`s and handing them to `textView.keyDown(with:)` — the same
/// seam live typing uses, so snippets and completion behave identically on replay.
/// Ceiling: menu key-equivalents (e.g. Cmd+D multi-caret) are consumed by the menu bar
/// before reaching `keyDown`, so they are neither recorded nor replayed; Option+Click
/// is mouse-only and likewise outside macros. One app-wide instance on `AppModel`.
@MainActor
final class MacroController: ObservableObject {
    @Published private(set) var isRecording = false
    /// The most recently finished recording (empty until the first `stopRecording()`).
    @Published private(set) var lastMacro: [KeyEventRecord] = []

    private var recordedEvents: [KeyEventRecord] = []

    /// Cmd+Opt+M, the menu shortcut that toggles recording. A keystroke matching this
    /// while an editor is focused reaches `record(_:)` (via `SnippetTextView.keyDown`)
    /// as well as the menu action — dropped here so the stop command never ends up
    /// inside its own macro.
    private static let stopShortcutCharacter = "m"
    private static let stopShortcutModifiers: NSEvent.ModifierFlags = [.command, .option]

    func startRecording() {
        recordedEvents = []
        isRecording = true
    }

    func stopRecording() {
        isRecording = false
        lastMacro = recordedEvents
        recordedEvents = []
    }

    /// Called from `SnippetTextView.keyDown` before its normal dispatch, only while
    /// `isRecording` is true.
    func record(_ event: NSEvent) {
        guard isRecording, !isStopShortcut(event) else { return }
        recordedEvents.append(
            KeyEventRecord(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue,
                characters: event.characters ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? ""
            )
        )
    }

    /// Replays each recorded event into `textView` in order. Never replays while a
    /// recording is in progress (that would record the replay into itself). Events that
    /// fail to synthesize (rare — see `NSEvent.keyEvent(with:...)`) are skipped rather
    /// than aborting the whole macro.
    func replay(_ events: [KeyEventRecord], into textView: STTextView) {
        guard !isRecording else { return }
        for record in events {
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: record.modifiers),
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: textView.window?.windowNumber ?? 0,
                context: nil,
                characters: record.characters,
                charactersIgnoringModifiers: record.charactersIgnoringModifiers,
                isARepeat: false,
                keyCode: record.keyCode
            ) else { continue }
            textView.keyDown(with: event)
        }
    }

    private func isStopShortcut(_ event: NSEvent) -> Bool {
        // Masked equality (not `.contains`): a superset check would wrongly swallow
        // Cmd+Opt+Shift+M as if it were the plain Cmd+Opt+M stop shortcut.
        event.charactersIgnoringModifiers?.lowercased() == Self.stopShortcutCharacter
            && event.modifierFlags.intersection([.command, .option, .shift, .control]) == Self.stopShortcutModifiers
    }
}
