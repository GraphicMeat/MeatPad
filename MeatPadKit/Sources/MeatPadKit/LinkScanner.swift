import Foundation

/// One URL found in plain text: where it sits (UTF-16, so it drops straight into
/// `NSAttributedString` / `STTextView` ranges) and what it points at.
public struct DetectedLink: Equatable, Sendable {
    public let range: NSRange
    public let url: URL

    public init(range: NSRange, url: URL) {
        self.range = range
        self.url = url
    }
}

/// Finds the links in a plain-text buffer — the one detector behind both surfaces that draw
/// them (board cards and the note editor), so a URL is the same URL in both.
///
/// `NSDataDetector` rather than a regex on purpose: it already knows bare `www.` hosts,
/// email addresses (handed back as `mailto:`), IDN, and where a URL stops when a sentence
/// ends on it — all of which a hand-rolled pattern gets wrong on the first real paragraph.
public enum LinkScanner {
    /// `NSDataDetector` inherits `NSRegularExpression`'s thread-safe matching, and building
    /// one costs more than a match does — so it is made once and shared.
    private static let detector =
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Every link in `text`, or only those inside `range` when one is given (the note editor
    /// scans the painted window, never the whole document).
    ///
    /// ponytail: bridges `text` to `NSString` per call. Fine for notes and cards; if this ever
    /// runs over a multi-hundred-MB buffer, hoist the bridge to the caller.
    public static func links(in text: String, range: NSRange? = nil) -> [DetectedLink] {
        guard let detector else { return [] }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let scope = range.map { NSIntersectionRange($0, full) } ?? full
        guard scope.length > 0 else { return [] }
        return detector.matches(in: text, options: [], range: scope).compactMap { match in
            guard let url = match.url else { return nil }
            return DetectedLink(range: match.range, url: url)
        }
    }

    /// Whether the text carries a link at all — the paste hint's question, which stops at the
    /// first hit instead of collecting every match.
    public static func containsLink(_ text: String) -> Bool {
        guard let detector else { return false }
        let ns = text as NSString
        guard ns.length > 0 else { return false }
        return detector.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length))?.url != nil
    }
}
