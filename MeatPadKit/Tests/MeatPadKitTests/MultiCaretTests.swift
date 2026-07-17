import XCTest
@testable import MeatPadKit

final class MultiCaretTests: XCTestCase {
    func testFindsNextAfterAnchorSkippingSelected() {
        // "foo foo foo": first foo selected (start 0), anchor ends at 3 → next is start 4.
        let next = MultiCaret.nextMatch(in: "foo foo foo", needle: "foo", afterEnd: 3, selectedStarts: [0])
        XCTAssertEqual(next, NSRange(location: 4, length: 3))
    }

    func testWrapsAroundToStart() {
        // Anchor at last occurrence (start 8, ends 11); 8 selected → wrap forward finds start 0.
        let next = MultiCaret.nextMatch(in: "foo foo foo", needle: "foo", afterEnd: 11, selectedStarts: [8])
        XCTAssertEqual(next, NSRange(location: 0, length: 3))
    }

    func testExhaustedReturnsNil() {
        // Every occurrence already selected → no-op.
        let next = MultiCaret.nextMatch(in: "foo foo foo", needle: "foo", afterEnd: 3, selectedStarts: [0, 4, 8])
        XCTAssertNil(next)
    }

    func testCaseSensitive() {
        // "Foo" must not match "foo".
        let next = MultiCaret.nextMatch(in: "foo Foo foo", needle: "Foo", afterEnd: 7, selectedStarts: [4])
        XCTAssertNil(next)
    }

    func testEmptyNeedleReturnsNil() {
        XCTAssertNil(MultiCaret.nextMatch(in: "abc", needle: "", afterEnd: 0, selectedStarts: []))
    }
}
