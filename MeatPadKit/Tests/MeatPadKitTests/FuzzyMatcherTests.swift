import XCTest
@testable import MeatPadKit

final class FuzzyMatcherTests: XCTestCase {

    // MARK: - Basic subsequence matching

    func testMatchesInitialismAcrossBoundaries() {
        let candidates = ["Notes/NoteWindowViewModel.swift"]
        let matches = FuzzyMatcher.rank(query: "nwvm", candidates: candidates)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].candidateIndex, 0)
    }

    func testBoundaryHeavyCandidateOutranksScatteredMatch() {
        let candidates = [
            "an editor with very messy code",       // scattered, no boundary bonuses
            "Notes/NoteWindowViewModel.swift",       // boundary + consecutive heavy
        ]
        let matches = FuzzyMatcher.rank(query: "nwvm", candidates: candidates)
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches[0].candidateIndex, 1, "boundary-heavy candidate should rank first")
        XCTAssertGreaterThan(matches[0].score, matches[1].score)
    }

    func testMatchedIndicesPointAtActualCharacters() {
        let matches = FuzzyMatcher.rank(query: "ab", candidates: ["xaby"])
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].matchedIndices, [1, 2])
    }

    // MARK: - Non-subsequence

    func testNonSubsequenceReturnsNoMatch() {
        let matches = FuzzyMatcher.rank(query: "xyz", candidates: ["abc"])
        XCTAssertTrue(matches.isEmpty)
    }

    func testNonSubsequenceCandidateIsExcludedButOthersStillMatch() {
        let matches = FuzzyMatcher.rank(query: "ab", candidates: ["nope", "abzz"])
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].candidateIndex, 1)
    }

    // MARK: - Case insensitivity

    func testMatchIsCaseInsensitive() {
        let matches = FuzzyMatcher.rank(query: "NWVM", candidates: ["Notes/NoteWindowViewModel.swift"])
        XCTAssertEqual(matches.count, 1)

        let matchesLowerQuery = FuzzyMatcher.rank(query: "nwvm", candidates: ["NOTES/NOTEWINDOWVIEWMODEL.SWIFT"])
        XCTAssertEqual(matchesLowerQuery.count, 1)
    }

    // MARK: - Empty query

    func testEmptyQueryMatchesAllWithZeroScoreAndNoIndices() {
        let candidates = ["a.swift", "b.swift", "c.swift"]
        let matches = FuzzyMatcher.rank(query: "", candidates: candidates)
        XCTAssertEqual(matches.count, 3)
        for (offset, match) in matches.enumerated() {
            XCTAssertEqual(match.candidateIndex, offset)
            XCTAssertEqual(match.score, 0)
            XCTAssertEqual(match.matchedIndices, [])
        }
    }

    func testEmptyQueryRespectsLimit() {
        let candidates = ["a.swift", "b.swift", "c.swift"]
        let matches = FuzzyMatcher.rank(query: "", candidates: candidates, limit: 2)
        XCTAssertEqual(matches.count, 2)
    }

    // MARK: - Limit

    func testLimitIsRespected() {
        let candidates = (0..<100).map { "file\($0).swift" }
        let matches = FuzzyMatcher.rank(query: "file", candidates: candidates, limit: 10)
        XCTAssertEqual(matches.count, 10)
    }

    func testDefaultLimitIsFifty() {
        let candidates = (0..<100).map { "file\($0).swift" }
        let matches = FuzzyMatcher.rank(query: "file", candidates: candidates)
        XCTAssertEqual(matches.count, 50)
    }

    // MARK: - Filename-tail vs directory match

    func testFilenameTailMatchOutranksDirectoryMatch() {
        let candidates = ["src/note.txt", "notxyz/e/other.txt"]
        let matches = FuzzyMatcher.rank(query: "note", candidates: candidates)
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches[0].candidateIndex, 0, "src/note.txt should outrank notxyz/e/other.txt for query 'note'")
        XCTAssertGreaterThan(matches[0].score, matches[1].score)
    }

    // MARK: - Stable ordering on ties

    func testTiesPreserveCandidateOrder() {
        // Identical filenames produce identical scores; original order must be kept.
        let candidates = ["dup.swift", "dup.swift", "dup.swift"]
        let matches = FuzzyMatcher.rank(query: "dup", candidates: candidates)
        XCTAssertEqual(matches.map(\.candidateIndex), [0, 1, 2])
    }

    // MARK: - Performance sanity

    func testTenThousandCandidatesIsFast() {
        let candidates = (0..<10_000).map { "Sources/Feature\($0)/Component\($0)ViewModel.swift" }
        let start = Date()
        let matches = FuzzyMatcher.rank(query: "fcvm", candidates: candidates, limit: 50)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.5, "10k candidate rank took \(elapsed)s, expected well under 0.5s")
        XCTAssertLessThanOrEqual(matches.count, 50)
    }
}
