import XCTest
@testable import MeatPadKit

final class TabSetTests: XCTestCase {

    private func urls(_ names: String...) -> [URL] {
        names.map { URL(fileURLWithPath: "/p/\($0)") }
    }

    func testOthersKeepsEveryTabExceptTheOneGivenInOrder() {
        let tabs = urls("a", "b", "c", "d")
        XCTAssertEqual(TabSet.others(than: tabs[1], in: tabs), urls("a", "c", "d"))
    }

    func testOthersOfTheOnlyTabIsEmpty() {
        let tabs = urls("a")
        XCTAssertEqual(TabSet.others(than: tabs[0], in: tabs), [])
    }

    func testToTheRightIsTheTabsAfterTheOneGiven() {
        let tabs = urls("a", "b", "c", "d")
        XCTAssertEqual(TabSet.toTheRight(of: tabs[1], in: tabs), urls("c", "d"))
    }

    func testToTheRightOfTheLastTabIsEmpty() {
        let tabs = urls("a", "b")
        XCTAssertEqual(TabSet.toTheRight(of: tabs[1], in: tabs), [])
    }

    func testToTheRightOfATabThatIsNotOpenIsEmpty() {
        XCTAssertEqual(TabSet.toTheRight(of: URL(fileURLWithPath: "/p/zzz"), in: urls("a", "b")), [])
    }
}
