import XCTest
@testable import MeatPadKit

final class HighlightEngineTests: XCTestCase {

    private func fullRange(_ s: String) -> NSRange { NSRange(location: 0, length: (s as NSString).length) }

    func testUnknownGrammarFailsToBuild() {
        XCTAssertNil(HighlightEngine(languageID: "nope"))
    }

    func testSpansMatchADirectHighlighterPass() async throws {
        let source = """
        def greet(name):
            return "hi " + name
        """
        let engine = try XCTUnwrap(HighlightEngine(languageID: "python"))
        let direct = try XCTUnwrap(Highlighter(languageID: "python"))
        direct.setText(source)
        let expected = direct.highlights(in: fullRange(source))

        await engine.replace(text: source)
        let spans = await engine.spans(in: fullRange(source))
        XCTAssertFalse(spans.isEmpty)
        XCTAssertEqual(spans, expected)
    }

    /// The engine is reused across passes, so a second pass must reflect the new text
    /// rather than the tree (and sublayers) the first pass left behind.
    func testASecondReplaceSupersedesTheFirst() async throws {
        let engine = try XCTUnwrap(HighlightEngine(languageID: "json"))
        await engine.replace(text: #"{"a": 1}"#)
        _ = await engine.spans(in: fullRange(#"{"a": 1}"#))

        let second = #"{"second": 2}"#
        await engine.replace(text: second)
        let spans = await engine.spans(in: fullRange(second))
        XCTAssertFalse(spans.isEmpty)
        for span in spans {
            XCTAssertLessThanOrEqual(span.range.upperBound, (second as NSString).length, "span escapes the current text")
        }
    }

    func testACancelledQueryReturnsNothingInsteadOfParsing() async throws {
        let engine = try XCTUnwrap(HighlightEngine(languageID: "json"))
        await engine.replace(text: #"{"a": 1}"#)
        let task = Task { await engine.spans(in: self.fullRange(#"{"a": 1}"#)) }
        task.cancel()
        let spans = await task.value
        XCTAssertEqual(spans, [])
    }

    // MARK: - Windowed injection resolution

    /// A windowed query must not return spans from outside the window, and asking for the
    /// window first must not poison a later full-document query — injections resolve
    /// cumulatively.
    func testWindowedQueryStaysInRangeAndDoesNotBlockALaterFullQuery() async throws {
        let source = ([String](repeating: "# Heading\n\nSome *emphasis* and `code` here.\n", count: 40)).joined()
        let window = NSRange(location: 0, length: 60)

        let windowed = try XCTUnwrap(HighlightEngine(languageID: "markdown"))
        await windowed.replace(text: source)
        let windowSpans = await windowed.spans(in: window)
        XCTAssertFalse(windowSpans.isEmpty)
        for span in windowSpans {
            XCTAssertTrue(NSIntersectionRange(span.range, window).length > 0, "span outside the requested window")
        }
        let thenFull = await windowed.spans(in: fullRange(source))

        let direct = try XCTUnwrap(HighlightEngine(languageID: "markdown"))
        await direct.replace(text: source)
        let fullOnly = await direct.spans(in: fullRange(source))

        XCTAssertEqual(thenFull, fullOnly, "resolving a window first changed the full-document result")
    }

    /// Injected spans (markdown_inline emphasis) must actually appear once the range is
    /// queried — proves deferred resolution resolves rather than silently skipping.
    func testInjectedSpansResolveForTheQueriedRange() async throws {
        let source = "# Title\n\nSome *emphasis* here.\n"
        let engine = try XCTUnwrap(HighlightEngine(languageID: "markdown"))
        await engine.replace(text: source)
        let spans = await engine.spans(in: fullRange(source))
        XCTAssertTrue(spans.contains { $0.capture.contains("emphasis") },
                      "no injected markdown_inline span found: \(spans.map(\.capture))")
    }
}
