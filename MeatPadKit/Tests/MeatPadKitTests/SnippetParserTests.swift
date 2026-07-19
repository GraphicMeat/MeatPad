import XCTest
@testable import MeatPadKit

final class SnippetParserTests: XCTestCase {

    // MARK: - Plain text

    func testPlainTextPassesThrough() throws {
        let parsed = try SnippetParser.parse("hello world")
        XCTAssertEqual(parsed.nodes, [.text("hello world"), .tabStop(index: 0, placeholder: [])])
    }

    // MARK: - Basic tab stops

    func testBareTabStopParsesWithEmptyPlaceholder() throws {
        let parsed = try SnippetParser.parse("foo $1 bar")
        XCTAssertEqual(parsed.nodes, [
            .text("foo "),
            .tabStop(index: 1, placeholder: []),
            .text(" bar"),
            .tabStop(index: 0, placeholder: []),
        ])
    }

    func testPlaceholderTabStopParses() throws {
        let parsed = try SnippetParser.parse("${1:x}")
        XCTAssertEqual(parsed.nodes, [
            .tabStop(index: 1, placeholder: [.text("x")]),
            .tabStop(index: 0, placeholder: []),
        ])
    }

    // MARK: - Nesting

    func testNestedPlaceholdersParse() throws {
        let parsed = try SnippetParser.parse("${1:foo ${2:bar}}")
        XCTAssertEqual(parsed.nodes, [
            .tabStop(index: 1, placeholder: [
                .text("foo "),
                .tabStop(index: 2, placeholder: [.text("bar")]),
            ]),
            .tabStop(index: 0, placeholder: []),
        ])
    }

    // MARK: - Mirrors

    func testMirrorSecondOccurrenceHasEmptyPlaceholder() throws {
        let parsed = try SnippetParser.parse("${1:x} $1")
        XCTAssertEqual(parsed.nodes, [
            .tabStop(index: 1, placeholder: [.text("x")]),
            .text(" "),
            .tabStop(index: 1, placeholder: []),
            .tabStop(index: 0, placeholder: []),
        ])
    }

    func testMirrorWrittenWithPlaceholderStillEmptiedInFavorOfPrimary() throws {
        // Primary defines the placeholder; a later occurrence written with its own
        // placeholder text is still just a mirror with an empty placeholder.
        let parsed = try SnippetParser.parse("${1:first} ${1:second}")
        XCTAssertEqual(parsed.nodes, [
            .tabStop(index: 1, placeholder: [.text("first")]),
            .text(" "),
            .tabStop(index: 1, placeholder: []),
            .tabStop(index: 0, placeholder: []),
        ])
    }

    // MARK: - Escapes

    func testDollarEscapeProducesLiteralDollar() throws {
        let parsed = try SnippetParser.parse(#"\$1"#)
        XCTAssertEqual(parsed.nodes, [.text("$1"), .tabStop(index: 0, placeholder: [])])
    }

    func testBackslashEscapeProducesLiteralBackslash() throws {
        let parsed = try SnippetParser.parse(#"foo\\bar"#)
        XCTAssertEqual(parsed.nodes, [.text(#"foo\bar"#), .tabStop(index: 0, placeholder: [])])
    }

    func testEscapedClosingBraceInsidePlaceholder() throws {
        let parsed = try SnippetParser.parse(#"${1:foo \} bar}"#)
        XCTAssertEqual(parsed.nodes, [
            .tabStop(index: 1, placeholder: [.text("foo } bar")]),
            .tabStop(index: 0, placeholder: []),
        ])
    }

    // MARK: - $0 handling

    func testMissingDollarZeroIsImplicitlyAppended() throws {
        let parsed = try SnippetParser.parse("$1")
        XCTAssertEqual(parsed.nodes, [.tabStop(index: 1, placeholder: []), .tabStop(index: 0, placeholder: [])])
    }

    func testExplicitDollarZeroMidBodyIsRespectedWithNoExtraAppended() throws {
        let parsed = try SnippetParser.parse("foo $0 bar")
        XCTAssertEqual(parsed.nodes, [
            .text("foo "),
            .tabStop(index: 0, placeholder: []),
            .text(" bar"),
        ])
    }

    // MARK: - Errors

    func testUnclosedPlaceholderThrowsUnbalancedBrace() {
        XCTAssertThrowsError(try SnippetParser.parse("${1:unclosed")) { error in
            XCTAssertEqual(error as? SnippetParseError, .unbalancedBrace)
        }
    }

    func testRegexTransformThrowsInvalidStop() {
        XCTAssertThrowsError(try SnippetParser.parse("${1/a/b/}")) { error in
            XCTAssertEqual(error as? SnippetParseError, .invalidStop)
        }
    }

    // MARK: - Markdown builtin bodies (table skeleton, task list item)

    func testMarkdownTableSkeletonBodyParsesFourDistinctTabStopsPlusFinal() throws {
        let body = BuiltinSnippets.all.first { $0.trigger == "table" && $0.languageIDs.contains("markdown") }!.body
        let parsed = try SnippetParser.parse(body)
        XCTAssertEqual(flattenedTabStopIndices(parsed.nodes), [1, 2, 3, 4, 0])
    }

    func testMarkdownTaskListItemBodyParsesSingleTabStopPlusFinal() throws {
        let body = BuiltinSnippets.all.first { $0.trigger == "task" && $0.languageIDs.contains("markdown") }!.body
        let parsed = try SnippetParser.parse(body)
        XCTAssertEqual(flattenedTabStopIndices(parsed.nodes), [1, 0])
    }

    private func flattenedTabStopIndices(_ nodes: [SnippetNode]) -> [Int] {
        nodes.flatMap { node -> [Int] in
            switch node {
            case .text:
                return []
            case .tabStop(let index, let placeholder):
                return [index] + flattenedTabStopIndices(placeholder)
            }
        }
    }
}
