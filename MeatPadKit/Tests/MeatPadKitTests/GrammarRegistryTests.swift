import XCTest
import SwiftTreeSitter
@testable import MeatPadKit

/// Compiling a language's highlight queries (`ts_query_new`) is the single most expensive part of
/// opening an editor — measured at ~35% of the main thread while flipping between tabs. A language
/// is compiled once per app run and every editor shares the result.
final class GrammarRegistryTests: XCTestCase {

    func testAskingTwiceForALanguageReusesTheCompiledQueries() throws {
        let first = try XCTUnwrap(GrammarRegistry.configuration(for: "swift"))
        let second = try XCTUnwrap(GrammarRegistry.configuration(for: "swift"))
        let firstQuery = try XCTUnwrap(first.queries[.highlights])
        let secondQuery = try XCTUnwrap(second.queries[.highlights])
        XCTAssertTrue(firstQuery === secondQuery, "highlight queries were compiled again for a language already compiled")
    }

    func testUnknownLanguageIsNilEveryTime() {
        XCTAssertNil(GrammarRegistry.configuration(for: "klingon"))
        XCTAssertNil(GrammarRegistry.configuration(for: "klingon"))
    }

    func testDifferentLanguagesGetDifferentQueries() throws {
        let swift = try XCTUnwrap(GrammarRegistry.configuration(for: "swift")?.queries[.highlights])
        let python = try XCTUnwrap(GrammarRegistry.configuration(for: "python")?.queries[.highlights])
        XCTAssertFalse(swift === python)
    }

    func testThreadsAskingAtOnceShareOneCompilation() throws {
        GrammarRegistry.clearCache()
        let lock = NSLock()
        var queries: [Query] = []
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            if let query = GrammarRegistry.configuration(for: "go")?.queries[.highlights] {
                lock.lock(); queries.append(query); lock.unlock()
            }
        }
        XCTAssertEqual(queries.count, 8)
        let first = try XCTUnwrap(queries.first)
        XCTAssertTrue(queries.allSatisfy { $0 === first }, "concurrent first use compiled the language more than once")
    }

    func testPrewarmCompilesAheadOfTheEditor() async {
        GrammarRegistry.clearCache()
        XCTAssertFalse(GrammarRegistry.isCached("rust"))
        await HighlightEngine.prewarm(languageIDs: ["rust", "go", "klingon"])
        XCTAssertTrue(GrammarRegistry.isCached("rust"))
        XCTAssertTrue(GrammarRegistry.isCached("go"))
    }

    func testAHighlighterBuiltAfterPrewarmStillHighlights() async throws {
        await HighlightEngine.prewarm(languageIDs: ["swift"])
        let highlighter = try XCTUnwrap(Highlighter(languageID: "swift"))
        highlighter.setText("let answer = 42\n")
        XCTAssertFalse(highlighter.highlights(in: NSRange(location: 0, length: 16)).isEmpty,
                       "a highlighter sharing the cached queries produced no spans")
    }
}
