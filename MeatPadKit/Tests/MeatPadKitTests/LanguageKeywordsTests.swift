import XCTest
@testable import MeatPadKit

final class LanguageKeywordsTests: XCTestCase {

    func testSwiftContainsCoreKeywords() {
        let keywords = LanguageKeywords.keywords(for: "swift")
        XCTAssertTrue(keywords.contains("func"))
        XCTAssertTrue(keywords.contains("guard"))
        XCTAssertTrue(keywords.contains("protocol"))
        XCTAssertTrue(keywords.contains("any"))
    }

    func testPythonContainsCoreKeywords() {
        let keywords = LanguageKeywords.keywords(for: "python")
        XCTAssertTrue(keywords.contains("def"))
        XCTAssertTrue(keywords.contains("None"))
    }

    func testRustContainsCoreKeywords() {
        let keywords = LanguageKeywords.keywords(for: "rust")
        XCTAssertTrue(keywords.contains("fn"))
        XCTAssertTrue(keywords.contains("impl"))
    }

    func testGoContainsCoreKeywords() {
        let keywords = LanguageKeywords.keywords(for: "go")
        XCTAssertTrue(keywords.contains("func"))
        XCTAssertTrue(keywords.contains("chan"))
    }

    func testTypeScriptContainsCoreKeywords() {
        let keywords = LanguageKeywords.keywords(for: "typescript")
        XCTAssertTrue(keywords.contains("any"))
        XCTAssertTrue(keywords.contains("satisfies"))
    }

    func testCppContainsCoreKeywords() {
        let keywords = LanguageKeywords.keywords(for: "cpp")
        XCTAssertTrue(keywords.contains("static_assert"))
        XCTAssertFalse(keywords.contains("require"))
    }

    func testMarkupAndDataLanguagesReturnEmpty() {
        XCTAssertEqual(LanguageKeywords.keywords(for: "json"), [])
        XCTAssertEqual(LanguageKeywords.keywords(for: "markdown"), [])
        XCTAssertEqual(LanguageKeywords.keywords(for: "yaml"), [])
        XCTAssertEqual(LanguageKeywords.keywords(for: "html"), [])
        XCTAssertEqual(LanguageKeywords.keywords(for: "css"), [])
    }

    func testUnknownLanguageReturnsEmpty() {
        XCTAssertEqual(LanguageKeywords.keywords(for: "unknown"), [])
        XCTAssertEqual(LanguageKeywords.keywords(for: "not-a-real-language"), [])
    }

    func testEveryKnownLanguageReturnsSortedDedupedArray() {
        for language in Languages.all {
            let keywords = LanguageKeywords.keywords(for: language.id)
            XCTAssertEqual(keywords, keywords.sorted(), "\(language.id) keywords must be sorted")
            XCTAssertEqual(keywords, Array(Set(keywords)).sorted(), "\(language.id) keywords must be deduped")
        }
    }
}
