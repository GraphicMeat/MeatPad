import XCTest
import LanguageServerProtocol
@testable import MeatPadKit

final class GoToDefinitionTests: XCTestCase {
    private let rangeA = LSPRange(startPair: (1, 0), endPair: (1, 5))
    private let rangeB = LSPRange(startPair: (2, 0), endPair: (2, 5))

    func testNilResponseIsEmpty() {
        XCTAssertEqual(GoToDefinition.locations(from: nil), [])
    }

    func testOptionASingleLocation() {
        let location = Location(uri: "file:///a.swift", range: rangeA)
        let response: DefinitionResponse = .optionA(location)
        XCTAssertEqual(GoToDefinition.locations(from: response), [location])
    }

    func testOptionBMultipleLocations() {
        let locations = [
            Location(uri: "file:///a.swift", range: rangeA),
            Location(uri: "file:///b.swift", range: rangeB),
        ]
        let response: DefinitionResponse = .optionB(locations)
        XCTAssertEqual(GoToDefinition.locations(from: response), locations)
    }

    /// `LocationLink` carries both `targetRange` (the enclosing declaration) and
    /// `targetSelectionRange` (the identifier itself) — `locations(from:)` must pick
    /// `targetSelectionRange`, discriminating it from the wider `targetRange`.
    func testOptionCUsesTargetSelectionRangeNotTargetRange() {
        let enclosingRange = LSPRange(startPair: (0, 0), endPair: (10, 0))
        let identifierRange = LSPRange(startPair: (1, 4), endPair: (1, 9))
        let link = LocationLink(targetUri: "file:///a.swift", targetRange: enclosingRange, targetSelectionRange: identifierRange)
        let response: DefinitionResponse = .optionC([link])
        XCTAssertEqual(GoToDefinition.locations(from: response), [Location(uri: "file:///a.swift", range: identifierRange)])
    }

    func testOptionCMultipleLinks() {
        let link1 = LocationLink(targetUri: "file:///a.swift", targetRange: rangeA, targetSelectionRange: rangeA)
        let link2 = LocationLink(targetUri: "file:///b.swift", targetRange: rangeB, targetSelectionRange: rangeB)
        let response: DefinitionResponse = .optionC([link1, link2])
        XCTAssertEqual(GoToDefinition.locations(from: response), [
            Location(uri: "file:///a.swift", range: rangeA),
            Location(uri: "file:///b.swift", range: rangeB),
        ])
    }
}
