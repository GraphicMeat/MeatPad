import XCTest
@testable import MeatPadKit

final class FoldScannerTests: XCTestCase {

    // MARK: - Simple function block folds

    func testSimpleFunctionBlockFolds() {
        let text = "func foo() {\n    body\n}\n"
        let regions = FoldScanner.regions(in: text)
        XCTAssertEqual(regions.count, 1)

        let head = "func foo() {"
        let bodyLine = "    body"
        let headStart = 0
        let headEnd = head.utf16.count
        let bodyStart = headEnd // the newline right after the head line
        let bodyEnd = (head + "\n" + bodyLine).utf16.count // end of "    body", excluding its newline

        XCTAssertEqual(regions[0].headLineRange, headStart..<headEnd)
        XCTAssertEqual(regions[0].bodyRange, bodyStart..<bodyEnd)
        XCTAssertEqual(regions[0].level, 0)
    }

    // MARK: - Nested blocks produce nested regions with levels

    func testNestedBlocksProduceNestedRegionsWithLevels() {
        let text = """
        func foo() {
            if x {
                body
            }
        }
        """
        let regions = FoldScanner.regions(in: text)
        XCTAssertEqual(regions.count, 2, "outer func region and inner if region")

        // Sorted by head position: outer func first, then inner if.
        XCTAssertEqual(regions[0].level, 0)
        XCTAssertEqual(regions[1].level, 1)

        let lines = text.components(separatedBy: "\n")
        XCTAssertTrue(regions[0].headLineRange.lowerBound < regions[1].headLineRange.lowerBound)

        // Outer region's body must fully contain the inner region's head+body.
        XCTAssertTrue(regions[0].bodyRange.contains(regions[1].headLineRange.lowerBound))
        _ = lines
    }

    // MARK: - Blank lines inside a region don't split it

    func testBlankLinesInsideRegionDoNotSplitIt() {
        let text = "func foo() {\n    a\n\n    b\n}\n"
        let regions = FoldScanner.regions(in: text)
        XCTAssertEqual(regions.count, 1, "a single blank line inside the body must not create two regions")

        let expectedBodyEnd = "func foo() {\n    a\n\n    b".utf16.count
        XCTAssertEqual(regions[0].bodyRange.upperBound, expectedBodyEnd)
    }

    // MARK: - Trailing blank lines excluded from region

    func testTrailingBlankLinesExcludedFromRegion() {
        let text = "func foo() {\n    body\n\n\n}\n"
        let regions = FoldScanner.regions(in: text)
        XCTAssertEqual(regions.count, 1)

        // Body must end at "    body"'s content end, not extend through the
        // trailing blank lines before the closing brace.
        let expectedBodyEnd = "func foo() {\n    body".utf16.count
        XCTAssertEqual(regions[0].bodyRange.upperBound, expectedBodyEnd)
    }

    // MARK: - Tabs vs spaces mixed (tabWidth)

    func testTabsVsSpacesMixedRespectsTabWidth() {
        // Head at indent 0. Body line uses a single tab; with tabWidth 4 that's
        // column 4, deeper than the head's column 0, so it must fold.
        let text = "func foo() {\n\tbody\n}\n"
        let regions = FoldScanner.regions(in: text, tabWidth: 4)
        XCTAssertEqual(regions.count, 1)
        let expectedBodyEnd = "func foo() {\n\tbody".utf16.count
        XCTAssertEqual(regions[0].bodyRange.upperBound, expectedBodyEnd)
    }

    func testTabWidthOneStillFoldsDeeperTab() {
        // Sanity: even with tabWidth 1, a single leading tab is still column 1,
        // deeper than the head's column 0.
        let text = "if x:\n\tbody\n"
        let regions = FoldScanner.regions(in: text, tabWidth: 1)
        XCTAssertEqual(regions.count, 1)
    }

    // MARK: - Flat file -> no regions

    func testFlatFileProducesNoRegions() {
        let text = "line one\nline two\nline three\n"
        let regions = FoldScanner.regions(in: text)
        XCTAssertEqual(regions, [])
    }

    func testEmptyTextProducesNoRegions() {
        XCTAssertEqual(FoldScanner.regions(in: ""), [])
    }

    // MARK: - Region ranges are exact UTF-16 offsets (multi-byte char in head line)

    func testRegionRangesAreExactUTF16OffsetsWithMultiByteCharInHeadLine() {
        // "😀" is a surrogate pair: 2 UTF-16 code units, 1 Swift Character.
        let head = "func 😀foo() {"
        let text = head + "\n    body\n}\n"
        let regions = FoldScanner.regions(in: text)
        XCTAssertEqual(regions.count, 1)

        let headEnd = head.utf16.count
        XCTAssertEqual(regions[0].headLineRange, 0..<headEnd)
        XCTAssertNotEqual(headEnd, head.count, "sanity: the emoji must actually inflate the UTF-16 count vs Character count")

        let expectedBodyEnd = (head + "\n    body").utf16.count
        XCTAssertEqual(regions[0].bodyRange, headEnd..<expectedBodyEnd)
    }

    // MARK: - Minimum body of 1 line; no dangling region without a deeper follower

    func testLineFollowedByEqualOrShallowerIndentOpensNoRegion() {
        let text = "a\nb\nc\n"
        XCTAssertEqual(FoldScanner.regions(in: text), [])
    }

    func testHeadWithOnlyBlankLinesAfterOpensNoRegion() {
        // Nothing non-blank follows the last line, so it can't be a fold head.
        let text = "func foo() {\n\n\n"
        XCTAssertEqual(FoldScanner.regions(in: text), [])
    }

    // MARK: - Sibling regions at the same level, not nested

    func testSiblingBlocksAtSameLevelAreNotNested() {
        let text = "func a() {\n    x\n}\nfunc b() {\n    y\n}\n"
        let regions = FoldScanner.regions(in: text)
        XCTAssertEqual(regions.count, 2)
        XCTAssertEqual(regions[0].level, 0)
        XCTAssertEqual(regions[1].level, 0)
        XCTAssertTrue(regions[0].headLineRange.lowerBound < regions[1].headLineRange.lowerBound)
    }

    // MARK: - Dedent by multiple levels closes all enclosing regions at once

    func testDedentByMultipleLevelsClosesAllEnclosingRegions() {
        let text = """
        func foo() {
            if x {
                if y {
                    body
                }
            }
        }
        after
        """
        let regions = FoldScanner.regions(in: text)
        XCTAssertEqual(regions.count, 3)
        XCTAssertEqual(Set(regions.map(\.level)), Set([0, 1, 2]))
    }
}
