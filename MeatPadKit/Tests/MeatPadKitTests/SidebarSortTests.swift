import XCTest
@testable import MeatPadKit

final class SidebarSortTests: XCTestCase {

    private struct Row { let name: String; let created: Date? }

    private func sort(_ rows: [Row], by mode: SidebarSort) -> [String] {
        SidebarSorter.sort(rows, by: mode, name: { $0.name }, created: { $0.created }).map(\.name)
    }

    func testManualReturnsItemsUntouched() {
        let rows = [Row(name: "c", created: nil), Row(name: "a", created: nil), Row(name: "b", created: nil)]
        XCTAssertEqual(sort(rows, by: .manual), ["c", "a", "b"])
    }

    func testNameUsesLocalizedStandardCompare() {
        // Case/diacritic-insensitive, and numbers compare numerically ("Item 2" before "Item 10").
        let rows = [
            Row(name: "Item 10", created: nil),
            Row(name: "item 2", created: nil),
            Row(name: "Äpple", created: nil),
            Row(name: "apple", created: nil),
        ]
        XCTAssertEqual(sort(rows, by: .name), ["apple", "Äpple", "item 2", "Item 10"])
    }

    func testCreatedIsAscending() {
        let now = Date()
        let rows = [
            Row(name: "newest", created: now.addingTimeInterval(2)),
            Row(name: "oldest", created: now),
            Row(name: "middle", created: now.addingTimeInterval(1)),
        ]
        XCTAssertEqual(sort(rows, by: .created), ["oldest", "middle", "newest"])
    }

    /// nil dates sink to `.distantPast` (oldest), and equal/nil dates must keep their original
    /// relative order — `sort(by:)` alone doesn't guarantee that, which is exactly why
    /// `SidebarSorter` sorts on `(date, originalIndex)` instead.
    func testCreatedIsStableForNilAndEqualDates() {
        let shared = Date()
        let rows = [
            Row(name: "a", created: nil),
            Row(name: "b", created: nil),
            Row(name: "c", created: shared),
            Row(name: "d", created: shared),
            Row(name: "e", created: nil),
        ]
        XCTAssertEqual(sort(rows, by: .created), ["a", "b", "e", "c", "d"])
    }
}
