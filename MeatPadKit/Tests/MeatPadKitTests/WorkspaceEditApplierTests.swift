import XCTest
import LanguageServerProtocol
@testable import MeatPadKit

final class WorkspaceEditApplierTests: XCTestCase {
    // MARK: - apply(_:to:) — back-to-front application over one snapshot

    func testSingleEditReplacesRange() {
        let text = "let foo = 1"
        let edit = TextEdit(range: LSPRange(start: Position(line: 0, character: 4), end: Position(line: 0, character: 7)), newText: "bar")
        XCTAssertEqual(WorkspaceEditApplier.apply([edit], to: text), "let bar = 1")
    }

    func testNoEditsReturnsTextUnchanged() {
        XCTAssertEqual(WorkspaceEditApplier.apply([], to: "unchanged"), "unchanged")
    }

    /// Applying front-to-back would shift every later edit's offsets by the first edit's
    /// length delta; back-to-front against one snapshot must not.
    func testMultipleEditsApplyBackToFrontWithoutOffsetDrift() {
        let text = "foo foo foo"
        // Three non-overlapping occurrences of "foo" at 0, 4, 8 — replace each with "quux"
        // (longer than "foo"), which would corrupt later ranges if earlier ones weren't
        // applied last.
        let edits = [
            TextEdit(range: LSPRange(start: Position(line: 0, character: 0), end: Position(line: 0, character: 3)), newText: "quux"),
            TextEdit(range: LSPRange(start: Position(line: 0, character: 4), end: Position(line: 0, character: 7)), newText: "quux"),
            TextEdit(range: LSPRange(start: Position(line: 0, character: 8), end: Position(line: 0, character: 11)), newText: "quux"),
        ]
        XCTAssertEqual(WorkspaceEditApplier.apply(edits, to: text), "quux quux quux")
    }

    /// Order of the input array must not matter — only the ranges do.
    func testEditOrderInInputDoesNotMatter() {
        let text = "aaa bbb ccc"
        let edits = [
            TextEdit(range: LSPRange(start: Position(line: 0, character: 8), end: Position(line: 0, character: 11)), newText: "Z"),
            TextEdit(range: LSPRange(start: Position(line: 0, character: 0), end: Position(line: 0, character: 3)), newText: "X"),
            TextEdit(range: LSPRange(start: Position(line: 0, character: 4), end: Position(line: 0, character: 7)), newText: "Y"),
        ]
        XCTAssertEqual(WorkspaceEditApplier.apply(edits, to: text), "X Y Z")
    }

    func testInsertionAtZeroLengthRange() {
        let text = "foobar"
        let edit = TextEdit(range: LSPRange(start: Position(line: 0, character: 3), end: Position(line: 0, character: 3)), newText: "-")
        XCTAssertEqual(WorkspaceEditApplier.apply([edit], to: text), "foo-bar")
    }

    func testOverlappingRangesRejectTheWholeApplication() {
        let text = "abcdef"
        let edits = [
            TextEdit(range: LSPRange(start: Position(line: 0, character: 0), end: Position(line: 0, character: 4)), newText: "X"),
            TextEdit(range: LSPRange(start: Position(line: 0, character: 2), end: Position(line: 0, character: 6)), newText: "Y"),
        ]
        XCTAssertNil(WorkspaceEditApplier.apply(edits, to: text))
    }

    /// Adjacent (touching but not overlapping) ranges are fine — a common shape for
    /// consecutive replacements.
    func testAdjacentTouchingRangesAreNotOverlap() {
        let text = "abcdef"
        let edits = [
            TextEdit(range: LSPRange(start: Position(line: 0, character: 0), end: Position(line: 0, character: 3)), newText: "XYZ"),
            TextEdit(range: LSPRange(start: Position(line: 0, character: 3), end: Position(line: 0, character: 6)), newText: "123"),
        ]
        XCTAssertEqual(WorkspaceEditApplier.apply(edits, to: text), "XYZ123")
    }

    func testOneOutOfBoundsRangeAbortsTheWholeFile() {
        let text = "short"
        let edits = [
            TextEdit(range: LSPRange(start: Position(line: 0, character: 0), end: Position(line: 0, character: 3)), newText: "OK"),
            // Line 5 doesn't exist in a one-line document.
            TextEdit(range: LSPRange(start: Position(line: 5, character: 0), end: Position(line: 5, character: 1)), newText: "nope"),
        ]
        XCTAssertNil(WorkspaceEditApplier.apply(edits, to: text))
    }

    func testInvertedRangeAbortsTheWholeFile() {
        let text = "abcdef"
        let edit = TextEdit(range: LSPRange(start: Position(line: 0, character: 4), end: Position(line: 0, character: 1)), newText: "x")
        XCTAssertNil(WorkspaceEditApplier.apply([edit], to: text))
    }

    // MARK: - normalize(_:) — changes vs documentChanges shape

    func testNormalizeChangesShape() {
        let edit = WorkspaceEdit(
            changes: ["file:///a.swift": [TextEdit(range: LSPRange(start: Position(line: 0, character: 0), end: Position(line: 0, character: 1)), newText: "x")]],
            documentChanges: nil
        )
        let result = WorkspaceEditApplier.normalize(edit)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.uri, "file:///a.swift")
        XCTAssertEqual(result.first?.edits.count, 1)
    }

    func testNormalizePrefersDocumentChangesOverChanges() {
        let documentChangesEdit = TextEdit(range: LSPRange(start: Position(line: 0, character: 0), end: Position(line: 0, character: 1)), newText: "doc")
        let changesEdit = TextEdit(range: LSPRange(start: Position(line: 0, character: 0), end: Position(line: 0, character: 1)), newText: "plain")
        let edit = WorkspaceEdit(
            changes: ["file:///a.swift": [changesEdit]],
            documentChanges: [.textDocumentEdit(TextDocumentEdit(
                textDocument: VersionedTextDocumentIdentifier(uri: "file:///a.swift", version: 1),
                edits: [documentChangesEdit]
            ))]
        )
        let result = WorkspaceEditApplier.normalize(edit)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.edits.first?.newText, "doc")
    }

    func testNormalizeDropsNonTextDocumentEditDocumentChanges() {
        let edit = WorkspaceEdit(
            changes: nil,
            documentChanges: [
                .createFile(CreateFile(kind: "create", uri: "file:///new.swift", options: nil)),
                .textDocumentEdit(TextDocumentEdit(
                    textDocument: VersionedTextDocumentIdentifier(uri: "file:///a.swift", version: nil),
                    edits: [TextEdit(range: LSPRange(start: Position(line: 0, character: 0), end: Position(line: 0, character: 1)), newText: "x")]
                )),
            ]
        )
        let result = WorkspaceEditApplier.normalize(edit)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.uri, "file:///a.swift")
    }

    func testNormalizeEmptyEditReturnsEmpty() {
        XCTAssertTrue(WorkspaceEditApplier.normalize(WorkspaceEdit(changes: nil, documentChanges: nil)).isEmpty)
    }
}
