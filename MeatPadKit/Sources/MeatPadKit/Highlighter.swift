import Foundation
import SwiftTreeSitter

/// A single highlighted region: a UTF-16 `NSRange` plus its dotted tree-sitter
/// capture name (e.g. "keyword.return", "string"), with any leading `@` stripped.
public struct HighlightSpan: Equatable, Sendable {
    public var range: NSRange
    public var capture: String

    public init(range: NSRange, capture: String) {
        self.range = range
        self.capture = capture
    }
}

/// Parses source text with a tree-sitter grammar and produces syntax-highlight spans.
///
/// P1 is deliberately simple: `setText` does a full reparse and precomputes every
/// span; `highlights(in:)` just filters the cached spans to the requested range.
/// Incremental reparsing can come later behind the same API.
public final class Highlighter {
    private let query: Query
    private let parser = Parser()

    private var spans: [HighlightSpan] = []

    /// Fails (returns nil) when no grammar is wired for `languageID`.
    public init?(languageID: String) {
        guard
            let config = GrammarRegistry.configuration(for: languageID),
            let query = config.queries[.highlights]
        else { return nil }

        self.query = query
        try? parser.setLanguage(config.language)
    }

    /// Full (re)parse. Precomputes all highlight spans for the new text.
    public func setText(_ text: String) {
        guard let tree = parser.parse(text) else {
            spans = []
            return
        }

        let cursor = query.execute(in: tree)
        // Resolving applies query predicates (#eq?, #match?, …) so captures are
        // classified the way the grammar intends. NamedRange.range is UTF-16.
        let named = cursor.resolve(with: .init(string: text)).highlights()
        spans = named.map {
            HighlightSpan(range: $0.range, capture: stripAt($0.name))
        }
    }

    /// Spans intersecting `range`, in document order.
    public func highlights(in range: NSRange) -> [HighlightSpan] {
        // ponytail: linear scan over precomputed spans. Fine for P1's full-reparse
        // model; swap for a sorted-range lookup if profiling says so.
        spans.filter { NSIntersectionRange($0.range, range).length > 0 }
    }

    private func stripAt(_ name: String) -> String {
        name.hasPrefix("@") ? String(name.dropFirst()) : name
    }
}
