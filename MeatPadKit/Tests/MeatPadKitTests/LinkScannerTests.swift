import XCTest
@testable import MeatPadKit

final class LinkScannerTests: XCTestCase {

    func testFindsBareURL() {
        let links = LinkScanner.links(in: "See https://example.com for more")
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].url.absoluteString, "https://example.com")
        XCTAssertEqual(links[0].range, NSRange(location: 4, length: 19))
    }

    /// A sentence that ends on a URL must not swallow the full stop into the link.
    func testTrailingSentencePunctuationIsNotPartOfTheLink() {
        let links = LinkScanner.links(in: "Read https://example.com/docs.")
        XCTAssertEqual(links.map(\.url.absoluteString), ["https://example.com/docs"])
    }

    func testSchemelessHostAndEmail() {
        let links = LinkScanner.links(in: "www.example.com or hi@example.com")
        XCTAssertEqual(links.map(\.url.absoluteString), ["http://www.example.com", "mailto:hi@example.com"])
    }

    /// Ranges are UTF-16, the space every attributed-string API works in — an emoji ahead of
    /// the link is two units, not one character.
    func testRangesAreUTF16Offsets() {
        let links = LinkScanner.links(in: "🎉 https://example.com")
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].range.location, 3)
    }

    func testPlainTextHasNoLinks() {
        XCTAssertTrue(LinkScanner.links(in: "just some notes about nothing").isEmpty)
        XCTAssertFalse(LinkScanner.containsLink("just some notes about nothing"))
    }

    func testScopeLimitsTheScan() {
        let text = "https://first.example.com and https://second.example.com"
        let head = NSRange(location: 0, length: 25)
        XCTAssertEqual(LinkScanner.links(in: text, range: head).map(\.url.host), ["first.example.com"])
    }

    func testScopeOutsideTheTextIsClamped() {
        XCTAssertTrue(LinkScanner.links(in: "hello", range: NSRange(location: 40, length: 10)).isEmpty)
    }

    func testContainsLink() {
        XCTAssertTrue(LinkScanner.containsLink("ping https://example.com"))
        XCTAssertFalse(LinkScanner.containsLink(""))
    }
}
