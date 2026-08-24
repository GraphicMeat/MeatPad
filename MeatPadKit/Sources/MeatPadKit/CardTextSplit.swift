import Foundation

/// One card's worth of pasted text, before it becomes a `Card`.
public struct CardDraft: Equatable, Sendable {
    public let title: String
    public let body: String?

    public init(title: String, body: String? = nil) {
        self.title = title
        self.body = body
    }
}

/// Turns a block of pasted text into cards. Pure and language-agnostic on purpose: the
/// on-device summarizer only speaks the Apple Intelligence languages, and a client's feedback
/// list arrives in whatever language the client writes in.
public enum CardTextSplit {

    /// A title longer than this is not a title. Past it the whole item is kept as the body so
    /// nothing pasted is ever lost, and the title is the truncated lead.
    private static let titleLimit = 120

    /// Every item of a pasted list, in order. A single paragraph yields exactly one draft, so
    /// callers can run every paste through this and only ask the user when `count > 1`.
    public static func drafts(from text: String) -> [CardDraft] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let groups = markerGroups(in: normalized) ?? paragraphs(in: normalized)
        return groups.compactMap(draft(from:))
    }

    /// The same text as exactly one card — what "keep as one" means when the user declines a
    /// split. The lead line still becomes the title; nothing is dropped.
    public static func single(from text: String) -> CardDraft? {
        draft(from: text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
    }

    // MARK: - Grouping

    /// Groups lines by list marker ("1.", "2)", "-", "•", …). nil when the text isn't a list,
    /// which is anything with fewer than two marked lines — one stray dash is not a list.
    private static func markerGroups(in text: String) -> [String]? {
        let lines = text.components(separatedBy: "\n")
        var groups: [[String]] = []
        var current: [String] = []
        var marked = 0

        for line in lines {
            if let stripped = stripMarker(line) {
                marked += 1
                if !current.isEmpty { groups.append(current) }
                current = [stripped]
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { groups.append(current) }

        guard marked >= 2 else { return nil }
        return groups.map { $0.joined(separator: "\n") }
    }

    /// The line without its list marker, or nil if it carries none.
    private static func stripMarker(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Bullets: a single glyph followed by space.
        if let first = trimmed.first, "-*•‣–—▪".contains(first) {
            let rest = trimmed.dropFirst()
            guard rest.first == " " else { return nil }
            return String(rest).trimmingCharacters(in: .whitespaces)
        }

        // Numbers: up to three digits, then "." or ")" then space. Bounded so a pasted date or
        // an amount ("2026. metai", "1200) ") can't masquerade as a list.
        let digits = trimmed.prefix { $0.isNumber }
        guard (1...3).contains(digits.count) else { return nil }
        var rest = trimmed.dropFirst(digits.count)
        guard let separator = rest.first, separator == "." || separator == ")" else { return nil }
        rest = rest.dropFirst()
        guard rest.first == " " else { return nil }
        return String(rest).trimmingCharacters(in: .whitespaces)
    }

    /// Blank-line separated blocks — the fallback shape for an unmarked paste.
    private static func paragraphs(in text: String) -> [String] {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Title / body

    private static func draft(from group: String) -> CardDraft? {
        let text = group.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let lead = firstSentence(of: text)
        guard lead.count > titleLimit else {
            let rest = String(text.dropFirst(lead.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return CardDraft(title: lead, body: rest.isEmpty ? nil : rest)
        }
        // Too long to be a title: lead with a word-boundary cut and keep the item whole below,
        // so the truncation never costs the user text.
        return CardDraft(title: truncated(lead), body: text)
    }

    /// Foundation's own sentence breaking, so "1,5 m." or "e.g." don't split an item mid-way.
    /// Falls back to the first line for text it finds no sentence in.
    private static func firstSentence(of text: String) -> String {
        var sentence: String?
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .substringNotRequired]) { _, range, _, stop in
            sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            stop = true
        }
        guard var lead = sentence, !lead.isEmpty else {
            return String(text.prefix(while: { $0 != "\n" }))
        }
        // A "sentence" that runs over a line break is really a heading plus its detail; the
        // title stops at the break so it stays one line.
        if let newline = lead.firstIndex(of: "\n") { lead = String(lead[..<newline]) }
        return lead.trimmingCharacters(in: .whitespaces)
    }

    private static func truncated(_ text: String) -> String {
        let head = text.prefix(titleLimit)
        guard let lastSpace = head.lastIndex(of: " ") else { return String(head) + "…" }
        return String(head[head.startIndex..<lastSpace]) + "…"
    }
}
