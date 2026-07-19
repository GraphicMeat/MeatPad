import Foundation
import LanguageServerProtocol

/// Document Symbols (0.7 LSP plan Task 5): `textDocument/documentSymbol` response
/// normalization. The response is one of two shapes — hierarchical `[DocumentSymbol]`
/// (modern servers) or flat `[SymbolInformation]` (older ones) — `flatten` collapses both
/// into one ordered list `DocumentSymbolsView` can filter/display without caring which shape
/// the server sent. Pure/reusable, same split rationale as `GoToDefinition`/`FindReferences`.
enum DocumentSymbols {
    /// One flattened row. `depth` is 0 for a top-level symbol, 1 for its direct children,
    /// etc. — `DocumentSymbolsView` turns this into an indentation marker rather than a real
    /// tree control (a flat, fuzzy-filterable list is the quick-open precedent this reuses;
    /// see that view's doc comment). Always empty (depth 0) for the flat `SymbolInformation`
    /// shape, which carries no parent/child structure.
    struct Item: Identifiable {
        let id = UUID()
        let name: String
        let detail: String?
        let kind: SymbolKind
        let range: LSPRange
        let depth: Int
    }

    static func flatten(_ response: DocumentSymbolResponse) -> [Item] {
        guard let response else { return [] }
        switch response {
        case .optionA(let symbols):
            return symbols.flatMap { flatten($0, depth: 0) }
        case .optionB(let infos):
            return infos.map { Item(name: $0.name, detail: $0.containerName, kind: $0.kind, range: $0.location.range, depth: 0) }
        }
    }

    /// `selectionRange` (the identifier itself) is used for the jump target — same choice
    /// `GoToDefinition.locations` makes for `LocationLink.targetSelectionRange` over the
    /// enclosing declaration's full range.
    private static func flatten(_ symbol: DocumentSymbol, depth: Int) -> [Item] {
        var items = [Item(name: symbol.name, detail: symbol.detail, kind: symbol.kind, range: symbol.selectionRange, depth: depth)]
        for child in symbol.children ?? [] {
            items += flatten(child, depth: depth + 1)
        }
        return items
    }
}
