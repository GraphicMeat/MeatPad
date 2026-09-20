import XCTest
@testable import MeatPadKit

final class BoardColumnMergeTests: XCTestCase {

    func testRoundTripsParseAndSerialize() {
        let a = ColumnKey(boardID: UUID(), columnID: UUID())
        let b = ColumnKey(boardID: UUID(), columnID: UUID())
        let keys: Set<ColumnKey> = [a, b]

        let serialized = BoardColumnMerge.serialize(keys)
        XCTAssertEqual(BoardColumnMerge.parse(serialized), keys)
    }

    func testMalformedEntriesAreDropped() {
        let good = ColumnKey(boardID: UUID(), columnID: UUID())
        let raw = "\(good.boardID.uuidString):\(good.columnID.uuidString),not-a-uuid:also-not,onlyOnePart,,\(UUID().uuidString)"
        XCTAssertEqual(BoardColumnMerge.parse(raw), [good])
    }

    func testParseOfEmptyStringIsEmpty() {
        XCTAssertEqual(BoardColumnMerge.parse(""), [])
    }

    /// Two sets holding the same members must serialize identically regardless of `Set`'s own
    /// (unordered) iteration order — otherwise the `AppStorage` value churns on every launch.
    func testSerializeIsOrderIndependent() {
        let a = ColumnKey(boardID: UUID(), columnID: UUID())
        let b = ColumnKey(boardID: UUID(), columnID: UUID())
        let c = ColumnKey(boardID: UUID(), columnID: UUID())

        let first = BoardColumnMerge.serialize([a, b, c])
        let second = BoardColumnMerge.serialize([c, a, b])
        XCTAssertEqual(first, second)
    }
}
