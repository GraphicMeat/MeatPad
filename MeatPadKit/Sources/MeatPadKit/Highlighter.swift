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

    private static let layerConfiguration = LanguageLayer.Configuration(
        maximumLanguageDepth: 4,
        languageProvider: Highlighter.resolveInjection
    )

    private let languageConfig: LanguageConfiguration
    private var layer: LanguageLayer
    private var text: String = ""
    /// Character ranges whose language injections have already been resolved.
    ///
    /// Resolution — not parsing — is what makes a large document expensive. Measured on a
    /// 6.5 MB markdown file: the root parse is 0.64s, and resolving `markdown_inline` across
    /// the whole document is the other ~16.7s and ~760 MB. So injections resolve per query
    /// range, and this set remembers what's already done.
    private var resolvedSet = IndexSet()

    /// Fails (returns nil) when no grammar is wired for `languageID`.
    public init?(languageID: String) {
        guard
            let config = GrammarRegistry.configuration(for: languageID),
            config.queries[.highlights] != nil,
            let layer = try? LanguageLayer(languageConfig: config, configuration: Self.layerConfiguration)
        else { return nil }

        self.languageConfig = config
        self.layer = layer
    }

    /// Parse `text`, deferring all injection resolution to `highlights(in:)`.
    ///
    /// Starts from a **fresh** `LanguageLayer` rather than editing the existing one.
    /// `resolveSublayers` only ever adds or updates sublayers — it never prunes one whose
    /// injection has gone away — so a reused layer keeps colouring prose as Swift after the
    /// fenced code block above it is deleted. A new layer costs nothing measurable next to
    /// the parse and makes stale sublayers impossible.
    public func setText(_ text: String) {
        if let fresh = try? LanguageLayer(languageConfig: languageConfig, configuration: Self.layerConfiguration) {
            layer = fresh
        }
        self.text = text
        resolvedSet = IndexSet()

        // Insert-everything into the fresh layer. tree-sitter byte offsets are UTF-16
        // offsets × 2 — the same math `LanguageLayer.replaceContent` uses internally. Points
        // stay `.zero`, exactly like its nil transformer: highlight queries are byte-based
        // and never consult row/column.
        let edit = InputEdit(
            startByte: 0,
            oldEndByte: 0,
            newEndByte: currentLength * 2,
            startPoint: .zero,
            oldEndPoint: .zero,
            newEndPoint: .zero
        )
        // Invalidated ranges are ignored: nothing is painted from this call, and every
        // query resolves its own range on demand.
        _ = layer.didChangeContent(LanguageLayer.Content(string: text), using: edit, resolveSublayers: false)
    }

    /// Spans intersecting `range`, in document order, across the layer and any sublayers.
    ///
    /// Resolves this range's injections first, if they aren't resolved already. The cost is
    /// proportional to the range, so ask for a viewport, not a document — resolving a whole
    /// large file is exactly what this design exists to avoid.
    public func highlights(in range: NSRange) -> [HighlightSpan] {
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: currentLength))
        guard clamped.length > 0, let integers = Range(clamped) else { return [] }

        let requested = IndexSet(integersIn: integers)
        let unresolved = requested.subtracting(resolvedSet)
        if !unresolved.isEmpty {
            _ = try? layer.resolveSublayers(with: LanguageLayer.Content(string: text), in: unresolved)
            resolvedSet.formUnion(requested)
        }

        let named = (try? layer.highlights(in: clamped, provider: text.predicateTextProvider)) ?? []
        return named.map { HighlightSpan(range: $0.range, capture: stripAt($0.name)) }
    }

    private var currentLength: Int { (text as NSString).length }

    private func stripAt(_ name: String) -> String {
        name.hasPrefix("@") ? String(name.dropFirst()) : name
    }
}

/// Serial, off-the-main-thread owner of a `Highlighter`.
///
/// Parsing a large document takes seconds (0.64s for 6.5 MB of markdown, and that is the
/// *fast* path — see `Highlighter.setText`), so it cannot run on the main thread; doing it
/// there pins a core for the duration and freezes the window. The actor gets it onto the
/// cooperative pool and serialises passes, so two parses can never touch the same
/// `LanguageLayer` at once.
public actor HighlightEngine {
    private let highlighter: Highlighter

    /// Fails (returns nil) when no grammar is wired for `languageID`.
    public init?(languageID: String) {
        guard let highlighter = Highlighter(languageID: languageID) else { return nil }
        self.highlighter = highlighter
    }

    /// Reparse the whole document. Injections are left unresolved until `spans(in:)` asks
    /// for a range.
    public func replace(text: String) {
        highlighter.setText(text)
    }

    /// Spans for `range` only, resolving that range's injections if needed.
    ///
    /// Cancellation is checked on entry only: a superseded pass still sitting in the
    /// actor's queue drops for free, but a parse already inside tree-sitter runs to
    /// completion (there is no C-level cancel hook to reach for).
    public func spans(in range: NSRange) -> [HighlightSpan] {
        guard !Task.isCancelled else { return [] }
        return highlighter.highlights(in: range)
    }
}
