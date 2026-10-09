import XCTest
@testable import MeatPadKit

final class MatchListRowsTests: XCTestCase {
    private func group(_ name: String, _ count: Int) -> FileMatchGroup {
        let file = URL(fileURLWithPath: "/p/\(name)")
        return FileMatchGroup(file: file, matches: (0..<count).map {
            SearchMatch(file: file, lineNumber: $0 + 1, lineText: "x", rangeInLine: 0..<1)
        })
    }

    func testHeaderThenRowsPerGroup() {
        let rows = MatchListRow.flatten([group("a", 2), group("b", 1)], collapsed: [])
        XCTAssertEqual(rows.map(\.kind), [.header(0), .match(0, 0), .match(0, 1), .header(1), .match(1, 0)])
    }

    func testCollapsedGroupKeepsOnlyHeader() {
        let groups = [group("a", 2), group("b", 1)]
        let rows = MatchListRow.flatten(groups, collapsed: [groups[0].file])
        XCTAssertEqual(rows.map(\.kind), [.header(0), .header(1), .match(1, 0)])
    }

    func testIDsStableAndUniqueAcrossGroupsAndCollapse() {
        let groups = [group("a", 3), group("b", 3)]
        let open = MatchListRow.flatten(groups, collapsed: [])
        XCTAssertEqual(Set(open.map(\.id)).count, open.count)
        let folded = MatchListRow.flatten(groups, collapsed: [groups[0].file])
        // Rows of the untouched group keep their identity when another group folds.
        XCTAssertEqual(open.filter { $0.id.hasPrefix("m:/p/b") }.map(\.id), folded.filter { $0.id.hasPrefix("m:/p/b") }.map(\.id))
    }
}
