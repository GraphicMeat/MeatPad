import Foundation

/// Ranks candidate strings (e.g. project-relative file paths) against a query
/// using case-insensitive subsequence matching, for quick-open style pickers.
public enum FuzzyMatcher {

    public struct Match: Equatable, Sendable {
        public let candidateIndex: Int
        public let score: Int
        public let matchedIndices: [Int]
    }

    private static let baseScore = 1
    private static let consecutiveBonus = 15
    private static let boundaryBonus = 10
    private static let startBonus = 10
    private static let gapPenaltyPerChar = 1

    /// Matches `query` against each candidate as a case-insensitive subsequence,
    /// scores the matches, and returns the top `limit` sorted by score descending
    /// (ties keep the candidates' original relative order). An empty query matches
    /// every candidate with score 0 and no matched indices. Candidates that don't
    /// contain `query` as a subsequence are omitted.
    public static func rank(query: String, candidates: [String], limit: Int = 50) -> [Match] {
        if query.isEmpty {
            return candidates.indices
                .prefix(limit)
                .map { Match(candidateIndex: $0, score: 0, matchedIndices: []) }
        }

        let queryChars = Array(query.lowercased())
        let matches = candidates.enumerated().compactMap { index, candidate in
            match(queryChars: queryChars, candidate: candidate, candidateIndex: index)
        }

        // Array.sorted is stable (Swift 5+), so equal-score matches keep their
        // original candidate order automatically.
        return matches.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    private static func match(queryChars: [Character], candidate: String, candidateIndex: Int) -> Match? {
        let chars = Array(candidate)
        guard !chars.isEmpty else { return nil }
        let lower = chars.map { Character($0.lowercased()) }
        let boundaries = boundaryFlags(for: chars)

        var matchedIndices: [Int] = []
        matchedIndices.reserveCapacity(queryChars.count)
        var searchStart = 0

        for (queryPosition, queryChar) in queryChars.enumerated() {
            var chosen: Int?
            if queryPosition == 0 {
                // Boundary-aware retry: prefer landing the first character on a
                // word/segment boundary (e.g. jump past "src/" into "note.txt")
                // over the leftmost occurrence, which tends to fall inside a
                // directory name and score worse.
                chosen = (searchStart..<lower.count).first { lower[$0] == queryChar && ($0 == 0 || boundaries[$0]) }
            }
            if chosen == nil {
                chosen = (searchStart..<lower.count).first { lower[$0] == queryChar }
            }
            guard let index = chosen else { return nil }
            matchedIndices.append(index)
            searchStart = index + 1
        }

        return Match(
            candidateIndex: candidateIndex,
            score: score(matchedIndices: matchedIndices, boundaries: boundaries),
            matchedIndices: matchedIndices
        )
    }

    /// Marks positions that start a new "segment": right after a path/word
    /// separator, or a lowercase→uppercase case transition (camelCase).
    private static func boundaryFlags(for chars: [Character]) -> [Bool] {
        var boundaries = [Bool](repeating: false, count: chars.count)
        guard chars.count > 1 else { return boundaries }
        for i in 1..<chars.count {
            let previous = chars[i - 1]
            if previous == "/" || previous == "_" || previous == "-" || previous == "." {
                boundaries[i] = true
            } else if previous.isLowercase && chars[i].isUppercase {
                boundaries[i] = true
            }
        }
        return boundaries
    }

    private static func score(matchedIndices: [Int], boundaries: [Bool]) -> Int {
        var total = 0
        for (position, index) in matchedIndices.enumerated() {
            total += baseScore
            if index == 0 {
                total += startBonus
            } else if boundaries[index] {
                total += boundaryBonus
            }
            if position > 0 {
                let gap = index - matchedIndices[position - 1] - 1
                total += gap == 0 ? consecutiveBonus : -(gap * gapPenaltyPerChar)
            }
        }
        return total
    }
}
