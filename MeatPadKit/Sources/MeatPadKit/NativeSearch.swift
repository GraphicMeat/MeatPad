import Foundation

/// Native Swift `SearchEngine`. Walks the project via `ProjectScanner.forEachFile` (shares its
/// ignored-name + hidden-file rules, builds no tree), reads each
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
        // Files are pulled from the walker as workers free up, so a big project never has its whole
        // file list, every file's bytes, or every match list alive at once; stops as soon as the
        // match cap is reached.
        defer { Self.returnFreedMemory() }
        var allMatches: [SearchMatch] = []
        try await withThrowingTaskGroup(of: [SearchMatch].self) { group in
            let maxFileSize = maxFileSize
            var walker = ProjectScanner.FileWalker(root: root)
            func addNext() -> Bool {
                guard !Task.isCancelled, let file = walker.next() else { return false }
                group.addTask { Self.searchFile(file, query: query, regex: regex, maxFileSize: maxFileSize) }
                return true
            }
            for _ in 0..<max(4, ProcessInfo.processInfo.activeProcessorCount * 2) {
                if !addNext() { break }
            }
            for try await matches in group {
                allMatches.append(contentsOf: matches)
                if allMatches.count >= maxMatches { group.cancelAll(); break }
                _ = addNext()
            }
        }

        allMatches.sort { lhs, rhs in
            if lhs.file.path != rhs.file.path { return lhs.file.path < rhs.file.path }
            return lhs.lineNumber < rhs.lineNumber
        }

        // Stops reading files once the cap is reached, so which matches survive a capped
        // search depends on read order; they are still returned sorted.
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
        // Pool workers never drain on their own between files, and the Foundation matching below
        // autoreleases (NSString bridges, regex results): without this a big search piles up.
        autoreleasepool {
            // Mapped, not read: the file's pages stay file-backed and are never copied to the heap.
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count <= maxFileSize else { return [] }
            guard !Self.isBinary(data) else { return [] }
            // Most files hold no hit at all: rule them out on the raw bytes, before decoding the text.
            if regex == nil, !Self.mayContain(data, query.pattern, caseSensitive: query.caseSensitive) { return [] }
            guard let content = String(data: data, encoding: .utf8) else { return [] }

            var matches: [SearchMatch] = []
            let utf8 = content.utf8
            var lineStart = utf8.startIndex
            var lineNumber = 1
            // Walks the lines one at a time, split on "\n" only (line numbers must agree with the
            // editor and Replace All), never holding an array of all of them.
            while true {
                let newline = utf8[lineStart...].firstIndex(of: 10)
                let line = String(decoding: utf8[lineStart..<(newline ?? utf8.endIndex)], as: UTF8.self)
                if let regex {
                    matches.append(contentsOf: Self.regexMatches(regex, in: line, lineNumber: lineNumber, file: url))
                } else {
                    matches.append(contentsOf: Self.literalMatches(query, in: line, lineNumber: lineNumber, file: url))
                }
                guard let newline else { break }
                lineStart = utf8.index(after: newline)
                lineNumber += 1
            }
            return matches
        }
    }

    /// Byte-level "could this file contain the pattern?" — never a false negative for an ASCII
    /// pattern, so it only saves work (a non-ASCII one is left to the full path, which also
    /// matches canonically-equivalent spellings). Scans the mapped bytes without copying them.
    private static func mayContain(_ data: Data, _ pattern: String, caseSensitive: Bool) -> Bool {
        let needle = Array(pattern.utf8)
        guard !needle.isEmpty, needle.count <= data.count else { return needle.isEmpty }
        if needle.contains(where: { $0 >= 0x80 }) { return true }
        return data.withUnsafeBytes { (haystack: UnsafeRawBufferPointer) -> Bool in
            if caseSensitive {
                return needle.withUnsafeBytes { memmem(haystack.baseAddress, haystack.count, $0.baseAddress, $0.count) != nil }
            }
            // ASCII case folding: OR-ing 0x20 maps A-Z onto a-z (and only touches letters we compare as letters).
            let folded = needle.map { $0 >= 65 && $0 <= 90 ? $0 | 0x20 : $0 }
            let isLetter = folded.map { $0 >= 97 && $0 <= 122 }
            let last = haystack.count - folded.count
            var i = 0
            while i <= last {
                var j = 0
                while j < folded.count, (isLetter[j] ? haystack[i + j] | 0x20 : haystack[i + j]) == folded[j] { j += 1 }
                if j == folded.count { return true }
                i += 1
            }
            return false
        }
    }

    /// Hands the pages the search freed back to the OS, so the app doesn't sit on its peak.
    private static func returnFreedMemory() {
        #if canImport(Darwin)
        _ = malloc_zone_pressure_relief(nil, 0)
        #endif
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
