import SwiftUI
import MeatPadKit

/// Bottom status bar for a note/code editor surface: language picker, line/char counts,
/// and the caret line's char count. Stateless — all values are handed in by the host.
struct EditorStatusBar: View {
    let text: String
    let cursor: Int
    let languageOverride: String?
    let language: Language?
    let onSelectLanguage: (String?) -> Void

    var body: some View {
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

            Spacer()

            Text("\(Self.lineCount(of: text)) lines")
            Text("\(text.count) chars")
            Text("line \(Self.currentLineLength(of: text, cursor: cursor)) chars")
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var menuLabel: String {
        let name = language?.name ?? "Plain Text"
        return languageOverride == nil ? "Automatic — \(name)" : name
    }

    // ponytail: O(n) scan per render (newline count + line lookup); fine at note/file
    // scale, revisit if huge-file perf ever becomes a complaint.

    static func lineCount(of text: String) -> Int {
        (text as NSString).components(separatedBy: "\n").count
    }

    static func currentLineLength(of text: String, cursor: Int) -> Int {
        let ns = text as NSString
        let clamped = min(max(cursor, 0), ns.length)
        let range = ns.lineRange(for: NSRange(location: clamped, length: 0))
        var line = ns.substring(with: range)
        if line.hasSuffix("\r\n") {
            line.removeLast(2)
        } else if line.hasSuffix("\n") || line.hasSuffix("\r") {
            line.removeLast()
        }
        return line.count
    }
}
