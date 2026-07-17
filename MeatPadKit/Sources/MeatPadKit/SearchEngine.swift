import Foundation

/// Parameters for a project-wide search (Cmd+Shift+F).
public struct SearchQuery: Equatable, Sendable {
    public var pattern: String
    public var isRegex: Bool
    public var caseSensitive: Bool
    public var wholeWord: Bool

    public init(pattern: String, isRegex: Bool = false, caseSensitive: Bool = false, wholeWord: Bool = false) {
        self.pattern = pattern
        self.isRegex = isRegex
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
    }
}

/// A single match within a file. `rangeInLine` is UTF-16 offsets into `lineText`,
/// matching `NSRange`/`NSString` conventions so both literal and regex matching
/// (and downstream `NSTextView`/`STTextView` consumers) share one coordinate space.
public struct SearchMatch: Equatable, Sendable {
    public let file: URL
    public let lineNumber: Int
    public let lineText: String
    public let rangeInLine: Range<Int>

    public init(file: URL, lineNumber: Int, lineText: String, rangeInLine: Range<Int>) {
        self.file = file
        self.lineNumber = lineNumber
        self.lineText = lineText
        self.rangeInLine = rangeInLine
    }
}

public protocol SearchEngine: Sendable {
    func search(_ query: SearchQuery, in root: URL) async throws -> [SearchMatch]
    // ponytail: NativeSearch now; RipgrepSearch conforming impl arrives with P4 packaging (vendored universal rg)
}
