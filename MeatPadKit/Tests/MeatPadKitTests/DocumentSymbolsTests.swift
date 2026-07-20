import XCTest
import LanguageServerProtocol
@testable import MeatPadKit

final class DocumentSymbolsTests: XCTestCase {
    private func range(_ line: Int) -> LSPRange {
        LSPRange(startPair: (line, 0), endPair: (line, 3))
    }

    func testNilResponseIsEmpty() {
        XCTAssertEqual(DocumentSymbols.flatten(nil).count, 0)
    }

    func testEmptyHierarchicalResponse() {
        let response: DocumentSymbolResponse = .optionA([])
        XCTAssertEqual(DocumentSymbols.flatten(response).count, 0)
    }

    func testEmptyFlatResponse() {
        let response: DocumentSymbolResponse = .optionB([])
        XCTAssertEqual(DocumentSymbols.flatten(response).count, 0)
    }

    /// A 3-level nested tree: pre-order depth-first walk, `depth` incrementing per level,
    /// siblings preserved in array order.
    func testThreeLevelNestingOrderAndDepth() {
        let grandchild = DocumentSymbol(name: "grandchild", kind: .variable, range: range(3), selectionRange: range(3))
        let child1 = DocumentSymbol(name: "child1", kind: .method, range: range(2), selectionRange: range(2), children: [grandchild])
        let child2 = DocumentSymbol(name: "child2", kind: .method, range: range(4), selectionRange: range(4))
        let root = DocumentSymbol(name: "root", kind: .class, range: range(1), selectionRange: range(1), children: [child1, child2])
        let response: DocumentSymbolResponse = .optionA([root])

        let items = DocumentSymbols.flatten(response)
        XCTAssertEqual(items.map(\.name), ["root", "child1", "grandchild", "child2"])
        XCTAssertEqual(items.map(\.depth), [0, 1, 2, 1])
    }

    /// `selectionRange` (the identifier), never `range` (the enclosing declaration), is the
    /// jump target.
    func testHierarchicalUsesSelectionRangeNotRange() {
        let enclosing = LSPRange(startPair: (0, 0), endPair: (10, 0))
        let identifier = LSPRange(startPair: (1, 4), endPair: (1, 9))
        let symbol = DocumentSymbol(name: "f", kind: .function, range: enclosing, selectionRange: identifier)
        let response: DocumentSymbolResponse = .optionA([symbol])
        XCTAssertEqual(DocumentSymbols.flatten(response).first?.range, identifier)
    }

    /// The flat `SymbolInformation` shape carries no parent/child structure — every row is
    /// depth 0, in response order.
    func testFlatShapeIsAllDepthZero() {
        let info1 = SymbolInformation(name: "a", kind: .function, location: Location(uri: "file:///x.swift", range: range(1)), containerName: "X")
        let info2 = SymbolInformation(name: "b", kind: .function, location: Location(uri: "file:///x.swift", range: range(2)), containerName: "X")
        let response: DocumentSymbolResponse = .optionB([info1, info2])

        let items = DocumentSymbols.flatten(response)
        XCTAssertEqual(items.map(\.name), ["a", "b"])
        XCTAssertEqual(items.map(\.depth), [0, 0])
        XCTAssertEqual(items.map(\.detail), ["X", "X"])
        XCTAssertEqual(items.map(\.range), [range(1), range(2)])
    }
}
