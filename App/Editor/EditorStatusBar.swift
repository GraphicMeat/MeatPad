import SwiftUI
import MeatPadKit

/// Bottom status bar for a note/code editor surface: language picker, line/word/char counts,
/// and the caret line's word/char counts. Stateless — all values are handed in by the host.
struct EditorStatusBar: View {
    let text: String
    let cursor: Int
    let languageOverride: String?
    let language: Language?
    let onSelectLanguage: (String?) -> Void
    /// Language server status text (e.g. "LSP ✓"), rendered after the language menu.
    /// `nil` hides it entirely — the default, so notes and other non-project surfaces
    /// are unaffected.
    var lspStatus: String? = nil
    /// Transient message (e.g. "Renamed in 3 files" — Task 6) shown next to `lspStatus`
    /// and cleared automatically by the owner (`ProjectViewModel.flashStatus`); `nil`
    /// hides it, same "the host decides, this view just renders" contract as `lspStatus`.
    var flashMessage: String? = nil

    /// Whole-document counts, refreshed by the `.task` below whenever `text` changes.
    /// Never computed in `body` — see `DocumentStats`.
    @State private var stats: DocumentStats?

    var body: some View {
        let line = Self.currentLine(of: text, cursor: cursor)
        let counts = stats ?? .empty
        HStack(spacing: 12) {
            Menu {
                Button(languageOverride == nil ? "✓ Automatic" : "Automatic") { onSelectLanguage(nil) }
                Divider()
                ForEach(Languages.all) { candidate in
                    Button(languageOverride == candidate.id ? "✓ \(candidate.name)" : candidate.name) {
                        onSelectLanguage(candidate.id)
                    }
                }
            } label: {
                Text(menuLabel)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if let lspStatus {
                Text(lspStatus)
            }
            if let flashMessage {
                Text(flashMessage)
                    .foregroundStyle(.primary)
                    .transition(.opacity)
                    .animation(.easeOut(duration: 0.2), value: flashMessage)
            }

            Spacer()

            Text("\(counts.lines) lines")
            Text("\(counts.words) words")
            Text("\(counts.characters) chars")
            Text("line \(DocumentStats.wordCount(of: line)) words \(line.count) chars")
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .task(id: text) {
            // First pass runs immediately so the counts are right on open; later passes
            // debounce, so holding a key down in a large file doesn't queue a full-document
            // walk per keystroke. Cancellation comes free with `.task(id:)`.
            if stats != nil {
                try? await Task.sleep(for: .milliseconds(150))
                if Task.isCancelled { return }
            }
            let snapshot = text
            stats = await Task.detached(priority: .utility) { DocumentStats.compute(snapshot) }.value
        }
    }

    private var menuLabel: String {
        let name = language?.name ?? String(localized: "Plain Text")
        return languageOverride == nil ? String(localized: "Automatic — \(name)") : name
    }

    /// The caret line only — `NSString.lineRange` plus one short substring, so this stays
    /// cheap enough to run per render even on a multi-megabyte document. Bridging back to
    /// `NSString` is O(1); it never copies the whole text.
    static func currentLine(of text: String, cursor: Int) -> String {
        let ns = text as NSString
        let clamped = min(max(cursor, 0), ns.length)
        let range = ns.lineRange(for: NSRange(location: clamped, length: 0))
        var line = ns.substring(with: range)
        if line.hasSuffix("\r\n") {
            line.removeLast(2)
        } else if line.hasSuffix("\n") || line.hasSuffix("\r") {
            line.removeLast()
        }
        return line
    }
}
