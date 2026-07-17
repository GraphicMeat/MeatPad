import SwiftUI
import AppKit
import MeatPadKit
import STTextView

/// One finished (or running) command's output, rendered by `OutputPanelView` in the
/// project window whose `hostID` matches.
struct PanelOutput: Identifiable {
    let id = UUID()
    let hostID: AnyHashable
    let commandName: String
    var stdout: String
    var stderr: String
    var exitCode: Int32?
    var isRunning: Bool
}

/// Everything a shell command needs from the focused editor, published via
/// `focusedSceneValue` by each editor host (note windows and project editor panes).
/// All accessors capture the STTextView weakly — a stale menu action on a closed
/// window degrades to a no-op.
struct EditorCommandContext {
    /// Identity of the hosting window's view model — routes panel output and the
    /// filter sheet to the window the command was invoked from.
    let hostID: AnyHashable
    /// Project windows render the output panel; note windows fall back to a new note.
    let panelCapable: Bool
    /// File's `lastPathComponent` for project tabs; the note's derived title for notes.
    /// Used for the print job title (Task 5) — not part of the shell-command environment.
    let displayName: String
    let languageID: String?
    let fileURL: URL?
    let projectRoot: URL?
    let selectedText: () -> String?
    let documentText: () -> String
    let caretOffset: () -> Int
    let replaceSelection: (String) -> Void
    let insertAtCaret: (String) -> Void
    /// Direct access to the focused editor's STTextView — for actions (macro replay) that
    /// need the view itself rather than one of the text-mutation closures above.
    let textView: () -> STTextView?

    /// Standard context over an editor's STTextView. `fileURL`/`projectRoot` are nil for notes.
    @MainActor
    static func make(
        hostID: AnyHashable,
        panelCapable: Bool,
        textView: @autoclosure @escaping () -> STTextView?,
        languageID: String?,
        displayName: String,
        fileURL: URL? = nil,
        projectRoot: URL? = nil
    ) -> EditorCommandContext {
        EditorCommandContext(
            hostID: hostID,
            panelCapable: panelCapable,
            displayName: displayName,
            languageID: languageID,
            fileURL: fileURL,
            projectRoot: projectRoot,
            selectedText: {
                guard let tv = textView(), tv.textSelection.length > 0 else { return nil }
                return ((tv.text ?? "") as NSString).substring(with: tv.textSelection)
            },
            documentText: { textView()?.text ?? "" },
            caretOffset: { textView()?.textSelection.location ?? 0 },
            replaceSelection: { output in
                guard let tv = textView() else { return }
                // With multiple carets, this acts on ONE selection only — `tv.textSelection`
                // returns the most-recent one (STTextView's selectedRange() = textSelections.last).
                // Commands aren't multi-caret aware.
                // TextMate semantics: no selection → the whole document is "the selection".
                let target = tv.textSelection.length > 0
                    ? tv.textSelection
                    : NSRange(location: 0, length: ((tv.text ?? "") as NSString).length)
                tv.insertText(output, replacementRange: target)
            },
            insertAtCaret: { output in
                guard let tv = textView() else { return }
                tv.insertText(output, replacementRange: NSRange(location: tv.textSelection.location, length: 0))
            },
            textView: textView
        )
    }

    /// TM_* fields derived lazily at run time (line/column/word math on the live buffer).
    func commandContext() -> CommandContext {
        let text = documentText() as NSString
        let caret = min(caretOffset(), text.length)
        let lineRange = text.length == 0 ? NSRange(location: 0, length: 0) : text.lineRange(for: NSRange(location: caret, length: 0))
        var line = 1
        for i in 0..<caret where text.character(at: i) == 10 { line += 1 } // '\n'
        return CommandContext(
            selectedText: selectedText(),
            filePath: fileURL?.path,
            projectDirectory: projectRoot?.path,
            lineNumber: line,
            columnNumber: caret - lineRange.location + 1,
            currentLine: text.length == 0 ? "" : text.substring(with: lineRange).trimmingCharacters(in: .newlines),
            currentWord: Self.word(in: text, at: caret),
            languageID: languageID
        )
    }

    private static func word(in text: NSString, at caret: Int) -> String? {
        func isWord(_ c: unichar) -> Bool {
            (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
        }
        var start = caret, end = caret
        while start > 0, isWord(text.character(at: start - 1)) { start -= 1 }
        while end < text.length, isWord(text.character(at: end)) { end += 1 }
        return start < end ? text.substring(with: NSRange(location: start, length: end - start)) : nil
    }
}

/// Runs saved commands and one-off filters, applying output per the command's mode.
/// One app-wide instance on `AppModel`; one command runs at a time.
@MainActor
final class CommandExecutor: ObservableObject {
    @Published var panelOutput: PanelOutput?
    @Published private(set) var isRunning = false
    /// Set by the Commands menu to request the Filter Through Command… sheet in the
    /// window owning this context; the matching window's `.sheet` consumes it.
    @Published var filterContext: EditorCommandContext?

    private var currentTask: Task<Void, Never>?

    func run(_ cmd: SavedCommand, context ctx: EditorCommandContext) {
        guard !isRunning else { return }
        isRunning = true

        let stdin: String?
        switch cmd.input {
        case .none: stdin = nil
        // TextMate fallback: "selection" input with nothing selected feeds the document.
        case .selection: stdin = ctx.selectedText() ?? ctx.documentText()
        case .document: stdin = ctx.documentText()
        }
        let environment = TMEnvironment.build(from: ctx.commandContext())

        if cmd.output == .outputPanel, ctx.panelCapable {
            panelOutput = PanelOutput(hostID: ctx.hostID, commandName: cmd.name, stdout: "", stderr: "", exitCode: nil, isRunning: true)
        }

        currentTask = Task {
            do {
                let result = try await CommandRunner().run(script: cmd.script, stdin: stdin, environment: environment, timeout: 30)
                finish(cmd, context: ctx, result: result)
            } catch {
                // Cancellation or spawn failure: tear down quietly; cancel() already
                // reflected the state for the cancel path.
                isRunning = false
                if var out = panelOutput, out.isRunning {
                    out.isRunning = false
                    out.stderr += out.stderr.isEmpty ? "(cancelled)" : "\n(cancelled)"
                    panelOutput = out
                }
            }
        }
    }

    func cancel() {
        currentTask?.cancel()
    }

    private func finish(_ cmd: SavedCommand, context ctx: EditorCommandContext, result: CommandResult) {
        isRunning = false
        let failed = result.exitCode != 0 || !result.stderr.isEmpty || result.timedOut

        var mode = cmd.output
        // Never splice a failure into the buffer — reroute to the panel (or a note).
        if failed, mode == .replaceSelection || mode == .insertAtCaret {
            mode = .outputPanel
        }
        if mode == .outputPanel, !ctx.panelCapable {
            mode = .newNote
        }

        switch mode {
        case .replaceSelection:
            ctx.replaceSelection(result.stdout)
        case .insertAtCaret:
            ctx.insertAtCaret(result.stdout)
        case .newNote:
            AppModel.shared.openNewNote(withContents: noteText(cmd, result))
        case .outputPanel:
            panelOutput = PanelOutput(
                hostID: ctx.hostID, commandName: cmd.name,
                stdout: result.stdout, stderr: result.stderr,
                exitCode: result.exitCode, isRunning: false
            )
        }
    }

    private func noteText(_ cmd: SavedCommand, _ result: CommandResult) -> String {
        var parts = ["$ \(cmd.name)"]
        if !result.stdout.isEmpty { parts.append(result.stdout) }
        if !result.stderr.isEmpty { parts.append("[stderr]\n" + result.stderr) }
        if result.timedOut { parts.append("(timed out)") }
        if result.exitCode != 0 { parts.append("(exit \(result.exitCode))") }
        return parts.joined(separator: "\n")
    }
}

/// "cmd+shift+r" → KeyboardShortcut. Modifiers: cmd/command, opt/option/alt,
/// shift, ctrl/control; the last component must be a single character. Anything
/// else → nil (menu item without a shortcut).
enum ShortcutParser {
    static func parse(_ string: String?) -> KeyboardShortcut? {
        guard let string, !string.isEmpty else { return nil }
        var modifiers: EventModifiers = []
        var key: Character?
        for part in string.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd", "command": modifiers.insert(.command)
            case "opt", "option", "alt": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            case "ctrl", "control": modifiers.insert(.control)
            default:
                guard part.count == 1, key == nil else { return nil }
                key = part.first
            }
        }
        guard let key else { return nil }
        return KeyboardShortcut(KeyEquivalent(key), modifiers: modifiers)
    }
}

// MARK: - Focused value

private struct FocusedEditorCommandContextKey: FocusedValueKey {
    typealias Value = EditorCommandContext
}

extension FocusedValues {
    /// The focused editor's shell-command context, published by every editor host so the
    /// app-level Commands menu targets whichever window is frontmost.
    var editorCommandContext: EditorCommandContext? {
        get { self[FocusedEditorCommandContextKey.self] }
        set { self[FocusedEditorCommandContextKey.self] = newValue }
    }
}
