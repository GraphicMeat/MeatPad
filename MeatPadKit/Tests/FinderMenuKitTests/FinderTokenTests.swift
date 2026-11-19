import XCTest
@testable import FinderMenuKit

final class FinderTokenTests: XCTestCase {

    private let hexDigits = Set("0123456789abcdef")

    func testTheDefaultsKeyAndMinimumLength() {
        XCTAssertEqual(FinderToken.defaultsKey, "finder.token")
        XCTAssertEqual(FinderToken.minimumLength, 32)
    }

    func testAGeneratedTokenIs64LowercaseHexCharacters() {
        let token = FinderToken.generate()
        XCTAssertEqual(token.count, 64, token)
        XCTAssertTrue(token.allSatisfy(hexDigits.contains), token)
    }

    func testTwoGeneratedTokensDiffer() {
        XCTAssertNotEqual(FinderToken.generate(), FinderToken.generate())
    }

    func testAGeneratedTokenIsUsable() {
        XCTAssertTrue(FinderToken.isUsable(FinderToken.generate()))
    }

    func testUsableTokens() {
        XCTAssertTrue(FinderToken.isUsable(String(repeating: "a", count: 32)), "exactly the minimum")
        XCTAssertTrue(FinderToken.isUsable(String(repeating: "0123456789ABCDEF", count: 4)), "uppercase hex")
    }

    func testUnusableTokens() {
        XCTAssertFalse(FinderToken.isUsable(nil))
        XCTAssertFalse(FinderToken.isUsable(""))
        XCTAssertFalse(FinderToken.isUsable(String(repeating: "a", count: 31)), "31 hex characters")
        XCTAssertFalse(FinderToken.isUsable(String(repeating: "a", count: 63) + "z"), "64 characters with a z")
        XCTAssertFalse(FinderToken.isUsable(String(repeating: "a", count: 63) + " "), "a space")
        XCTAssertFalse(FinderToken.isUsable(String(repeating: "a", count: 63) + "é"), "non-ASCII")
    }
}
