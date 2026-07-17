import Foundation

/// Native Swift `SearchEngine`. Walks the project tree via `ProjectScanner` (reuses its
/// ignored-name + hidden-file rules rather than re-walking the filesystem), reads each
/// candidate file concurrently, and matches literally or via `NSRegularExpression`.
public struct NativeSearch: SearchEngine {
    private let maxFileSize: Int
    private let maxMatches: Int

    public init(maxFileSize: Int = 4_000_000, maxMatches: Int = 10_000) {
        self.maxFileSize = maxFileSize
        self.maxMatches = maxMatches
    }

    public func search(_ query: SearchQuery, in root: URL) async throws -> [SearchMatch] {
        guard !query.pattern.isEmpty else { return [] }

        let regex = try Self.makeRegex(query)
        let files = ProjectScanner.flatFileList(ProjectScanner.scan(root: root, showHidden: false))

        var allMatches: [SearchMatch] = []
        try await withThrowingTaskGroup(of: [SearchMatch].self) { group in
            for file in files {
                if Task.isCancelled { break } // checked between files per spec
                let maxFileSize = maxFileSize
                group.addTask {
                    Self.searchFile(file, query: query, regex: regex, maxFileSize: maxFileSize)
                }
            }
            for try await matches in group {
                allMatches.append(contentsOf: matches)
            }
        }

        allMatches.sort { lhs, rhs in
            if lhs.file.path != rhs.file.path { return lhs.file.path < rhs.file.path }
            return lhs.lineNumber < rhs.lineNumber
        }

        // ponytail: cap silently after collecting everything rather than short-circuiting
        // the walk early; simplest correct behavior, revisit if huge repos make the
        // full walk itself (not just result size) a perf problem.
        if allMatches.count > maxMatches {
            allMatches.removeLast(allMatches.count - maxMatches)
        }
        return allMatches
    }

    private static func makeRegex(_ query: SearchQuery) throws -> NSRegularExpression? {
        guard query.isRegex else { return nil }
        var options: NSRegularExpression.Options = []
        if !query.caseSensitive { options.insert(.caseInsensitive) }
        return try NSRegularExpression(pattern: query.pattern, options: options)
    }

    private static func searchFile(
        _ url: URL, query: SearchQuery, regex: NSRegularExpression?, maxFileSize: Int
    ) -> [SearchMatch] {
        guard Self.fileSize(url) <= maxFileSize else { return [] }
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard !Self.isBinary(data) else { return [] }
        guard let content = String(data: data, encoding: .utf8) else { return [] }

        var matches: [SearchMatch] = []
        for (index, line) in content.components(separatedBy: "\n").enumerated() {
            let lineNumber = index + 1
            if let regex {
                matches.append(contentsOf: Self.regexMatches(regex, in: line, lineNumber: lineNumber, file: url))
            } else {
                matches.append(contentsOf: Self.literalMatches(query, in: line, lineNumber: lineNumber, file: url))
            }
        }
        return matches
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    private static func isBinary(_ data: Data) -> Bool {
        data.prefix(8192).contains(0)
    }

    private static func literalMatches(
        _ query: SearchQuery, in line: String, lineNumber: Int, file: URL
    ) -> [SearchMatch] {
        var results: [SearchMatch] = []
        let options: String.CompareOptions = query.caseSensitive ? [] : [.caseInsensitive]
        var searchStart = line.startIndex
        while searchStart < line.endIndex,
              let found = line.range(of: query.pattern, options: options, range: searchStart..<line.endIndex) {
            if !query.wholeWord || Self.isWholeWord(line: line, range: found) {
                let nsRange = NSRange(found, in: line)
                results.append(SearchMatch(
                    file: file, lineNumber: lineNumber, lineText: line,
                    rangeInLine: nsRange.location..<(nsRange.location + nsRange.length)
                ))
            }
            searchStart = found.upperBound
        }
        return results
    }

    private static func isWholeWord(line: String, range: Range<String.Index>) -> Bool {
        func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        if range.lowerBound > line.startIndex, isWordChar(line[line.index(before: range.lowerBound)]) {
            return false
        }
        if range.upperBound < line.endIndex, isWordChar(line[range.upperBound]) {
            return false
        }
        return true
    }

    private static func regexMatches(
        _ regex: NSRegularExpression, in line: String, lineNumber: Int, file: URL
    ) -> [SearchMatch] {
        let nsLine = line as NSString
        let fullRange = NSRange(location: 0, length: nsLine.length)
        return regex.matches(in: line, range: fullRange).map { result in
            SearchMatch(
                file: file, lineNumber: lineNumber, lineText: line,
                rangeInLine: result.range.location..<(result.range.location + result.range.length)
            )
        }
    }
}

/// Applies replacements to previously-found matches and writes files back to disk.
public enum SearchReplacer {
    /// Groups matches per file, re-verifies each match's recorded line still matches the
    /// file's current contents (stale matches → skip the whole file, counted in `skipped`),
    /// then applies replacements bottom-up (by line, then column, descending) so earlier
    /// offsets in the same file stay valid, and writes the file atomically.
    public static func replaceAll(
        matches: [SearchMatch], with template: String, query: SearchQuery
    ) throws -> (replaced: Int, skipped: Int) {
        let regex = try makeRegex(query)
        var replaced = 0
        var skipped = 0

        for (file, fileMatches) in Dictionary(grouping: matches, by: \.file) {
            guard let data = try? Data(contentsOf: file), let content = String(data: data, encoding: .utf8) else {
                skipped += fileMatches.count
                continue
            }
            var lines = content.components(separatedBy: "\n")

            let isStale = fileMatches.contains { match in
                let idx = match.lineNumber - 1
                return idx < 0 || idx >= lines.count || lines[idx] != match.lineText
            }
            if isStale {
                skipped += fileMatches.count
                continue
            }

            // Bottom-up: later lines first, and within a line, rightmost matches first,
            // so replacing one match never shifts the offsets of matches not yet applied.
            let ordered = fileMatches.sorted { lhs, rhs in
                if lhs.lineNumber != rhs.lineNumber { return lhs.lineNumber > rhs.lineNumber }
                return lhs.rangeInLine.lowerBound > rhs.rangeInLine.lowerBound
            }

            for match in ordered {
                let idx = match.lineNumber - 1
                let nsLine = lines[idx] as NSString
                let nsRange = NSRange(location: match.rangeInLine.lowerBound, length: match.rangeInLine.count)
                guard nsRange.location + nsRange.length <= nsLine.length else {
                    skipped += 1
                    continue
                }
                let replacementText = replacement(for: nsLine.substring(with: nsRange), template: template, regex: regex)
                lines[idx] = nsLine.replacingCharacters(in: nsRange, with: replacementText)
                replaced += 1
            }

            try Data(lines.joined(separator: "\n").utf8).write(to: file, options: .atomic)
        }

        return (replaced, skipped)
    }

    private static func makeRegex(_ query: SearchQuery) throws -> NSRegularExpression? {
        guard query.isRegex else { return nil }
        var options: NSRegularExpression.Options = []
        if !query.caseSensitive { options.insert(.caseInsensitive) }
        return try NSRegularExpression(pattern: query.pattern, options: options)
    }

    private static func replacement(for matchedText: String, template: String, regex: NSRegularExpression?) -> String {
        guard let regex else { return template }
        let nsMatched = matchedText as NSString
        guard let result = regex.firstMatch(in: matchedText, range: NSRange(location: 0, length: nsMatched.length)) else {
            return template
        }
        return regex.replacementString(for: result, in: matchedText, offset: 0, template: template)
    }
}
