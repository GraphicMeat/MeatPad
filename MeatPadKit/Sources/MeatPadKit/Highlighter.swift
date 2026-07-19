import Foundation
import SwiftTreeSitter
import SwiftTreeSitterLayer

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
/// Built on `LanguageLayer`, which resolves grammar injections (e.g. markdown's
/// inline text, fenced code blocks) into nested sublayers automatically. A
/// language with no injections behaves identically to a plain single-grammar
/// parse — there is only this one code path.
public final class Highlighter {
    /// Injection names arrive as grammar-native strings: markdown's injections.scm
    /// requests "markdown_inline" directly, and fenced code blocks request whatever
    /// the fence's info string says (often a short alias rather than our language id).
    private static let injectionAliases: [String: String] = [
        "js": "javascript",
        "ts": "typescript",
        "py": "python",
        "c++": "cpp",
        "sh": "bash",
        "shell": "bash",
    ]

    private static func resolveInjection(_ name: String) -> LanguageConfiguration? {
        GrammarRegistry.configuration(for: injectionAliases[name] ?? name)
    }

    private let layer: LanguageLayer
    private var text: String = ""

    /// Fails (returns nil) when no grammar is wired for `languageID`.
    public init?(languageID: String) {
        guard
            let config = GrammarRegistry.configuration(for: languageID),
            config.queries[.highlights] != nil
        else { return nil }

        let configuration = LanguageLayer.Configuration(
            maximumLanguageDepth: 4,
            languageProvider: Highlighter.resolveInjection
        )
        guard let layer = try? LanguageLayer(languageConfig: config, configuration: configuration) else {
            return nil
        }
        self.layer = layer
    }

    /// Full (re)parse via a replace-all edit. Injections (e.g. markdown's inline
    /// grammar, fenced code blocks) are resolved into sublayers as part of this call.
    public func setText(_ text: String) {
        self.text = text
        layer.replaceContent(with: text)
    }

    /// Spans intersecting `range`, in document order, across the layer and any
    /// resolved sublayers.
    public func highlights(in range: NSRange) -> [HighlightSpan] {
        let named = (try? layer.highlights(in: range, provider: text.predicateTextProvider)) ?? []
        return named.map { HighlightSpan(range: $0.range, capture: stripAt($0.name)) }
    }

    private func stripAt(_ name: String) -> String {
        name.hasPrefix("@") ? String(name.dropFirst()) : name
    }
}
