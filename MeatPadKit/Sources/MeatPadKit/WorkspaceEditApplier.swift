import Foundation
import LanguageServerProtocol

/// Pure application of an LSP `WorkspaceEdit` to already-loaded document text — the one
/// piece of Rename Symbol (0.7 LSP plan Task 6) with no AppKit/`EditorRegistry` dependency,
/// so it's unit-testable here rather than only exercisable by hand in the app. Everything
/// else (open-vs-closed-file dispatch, disk IO, the results summary) lives in
/// `App/Editor/RenameSymbol.swift` — this type only ever sees a URI and its edits.
public enum WorkspaceEditApplier {
    /// One target file's edits, normalized out of whichever shape the server sent.
    public struct FileEdit: Equatable, Sendable {
        public let uri: DocumentUri
        public let edits: [TextEdit]
    }

    /// `WorkspaceEdit.changes` (`[uri: [TextEdit]]`) and `.documentChanges`
    /// (`[WorkspaceEditDocumentChange]`) are two shapes for the same data; per the LSP
    /// spec a client that understands `documentChanges` should prefer it when both are
    /// present (it's the only shape that carries per-file version info). File-system
    /// operations inside `documentChanges` (`createFile`/`renameFile`/`deleteFile`) are
    /// dropped — this app's v1 rename can move text, not files.
    ///
    /// ponytail: no known LSP server actually returns file-move ops from a plain
    /// `textDocument/rename` (that's what `workspace/willRenameFiles` is for); upgrade
    /// this if one ever does.
    public static func normalize(_ edit: WorkspaceEdit) -> [FileEdit] {
        if let documentChanges = edit.documentChanges {
            return documentChanges.compactMap {
                guard case .textDocumentEdit(let change) = $0 else { return nil }
                return FileEdit(uri: change.textDocument.uri, edits: change.edits)
            }
        }
        if let changes = edit.changes {
            return changes.map { FileEdit(uri: $0.key, edits: $0.value) }
        }
        return []
    }

    /// Applies `edits` to `text` — ALL ranges are converted against this one snapshot
    /// first, then spliced back-to-front (descending by range start) so an earlier edit's
    /// insert/delete never shifts the offsets a later (already-applied) edit used. Returns
    /// `nil` — reject the WHOLE set, no partial application — if any edit's range fails to
    /// convert against `text` (`LSPPositionBridge.nsRange` already rejects out-of-bounds
    /// and inverted ranges) or if two edits' ranges overlap: an overlap means the edits
    /// disagree about the same span, and silently picking whichever applied last would be
    /// undefined behavior dressed up as success.
    ///
    /// ponytail ceiling: two *zero-length* edits (pure inserts) at the exact same offset
    /// don't count as "overlapping" by this check (they don't occupy any span to collide
    /// over) and apply in whatever order `sorted` happens to leave equal keys in — no
    /// known LSP server emits that shape for a rename, so it's not worth a tie-break rule.
    public static func apply(_ edits: [TextEdit], to text: String) -> String? {
        guard !edits.isEmpty else { return text }

        let ranged: [(range: NSRange, newText: String)] = edits.compactMap { edit in
            guard let range = LSPPositionBridge.nsRange(of: edit.range, in: text) else { return nil }
            return (range, edit.newText)
        }
        guard ranged.count == edits.count else { return nil }

        let descending = ranged.sorted { $0.range.location > $1.range.location }
        for i in 0..<(descending.count - 1) {
            let later = descending[i]      // higher start offset
            let earlier = descending[i + 1] // lower start offset
            guard later.range.location >= earlier.range.location + earlier.range.length else {
                return nil // overlap
            }
        }

        var result = text as NSString
        for (range, newText) in descending {
            result = result.replacingCharacters(in: range, with: newText) as NSString
        }
        return result as String
    }
}
