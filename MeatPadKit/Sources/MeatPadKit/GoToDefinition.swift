import Foundation
import LanguageServerProtocol

/// Go to Definition (0.7 LSP plan Task 4) response normalization. Pure/reusable — the
/// picker UI (`presentPicker` in the App target's `GoToDefinitionController.swift`) stays
/// out of the kit since it needs AppKit and editor/window navigation state.
public enum GoToDefinition {
    /// `textDocument/definition` collapses three possible response shapes into one flat
    /// list of jump targets. `LocationLink.targetSelectionRange` (the identifier's own
    /// range) is the `LocationLink` analogue of `Location.range` — `targetRange` (the
    /// enclosing declaration, e.g. the whole function body) is intentionally unused here.
    public static func locations(from response: DefinitionResponse) -> [Location] {
        guard let response else { return [] }
        switch response {
        case .optionA(let location):
            return [location]
        case .optionB(let locations):
            return locations
        case .optionC(let links):
            return links.map { Location(uri: $0.targetUri, range: $0.targetSelectionRange) }
        }
    }
}
