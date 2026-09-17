import XCTest
@testable import MeatPadKit

final class AttachmentExportTests: XCTestCase {
    func testNamesAfterTitleAndNumbersLaterAttachments() {
        XCTAssertEqual(AttachmentExport.fileName(title: "Hero banner", index: 0, ext: "png", fallback: "Attachment"), "Hero banner.png")
        XCTAssertEqual(AttachmentExport.fileName(title: "Hero banner", index: 1, ext: "png", fallback: "Attachment"), "Hero banner 2.png")
    }
    func testStripsPathSeparatorsNewlinesAndLeadingDots() {
        XCTAssertEqual(AttachmentExport.fileName(title: "a/b:c\nd", index: 0, ext: "jpg", fallback: "X"), "a b c d.jpg")
        XCTAssertEqual(AttachmentExport.fileName(title: "..hidden", index: 0, ext: "pdf", fallback: "X"), "hidden.pdf")
    }
    func testEmptyTitleUsesFallbackAndLongTitleIsCapped() {
        XCTAssertEqual(AttachmentExport.fileName(title: "  ", index: 0, ext: "png", fallback: "Attachment"), "Attachment.png")
        XCTAssertEqual(AttachmentExport.fileName(title: String(repeating: "x", count: 500), index: 0, ext: "png", fallback: "A").count, 120 + 4)
    }
}
