import Foundation

/// A node in a parsed TextMate-style snippet body.
public indirect enum SnippetNode: Equatable, Sendable {
    case text(String)
    /// `$N` → placeholder []; `${N:...}` → parsed children (nesting allowed).
    case tabStop(index: Int, placeholder: [SnippetNode])
}

/// The result of parsing a snippet body.
public struct ParsedSnippet: Equatable, Sendable {
    public let nodes: [SnippetNode]
}

public enum SnippetParseError: Error, Equatable {
    case unbalancedBrace
    case invalidStop
}

/// Hand-rolled recursive-descent parser for TextMate-style snippet bodies.
///
/// Supported syntax: plain text, `$N`, `${N:default}` (default may contain
/// nested tab stops and text), mirrors (repeated index — first occurrence is
/// the primary, later occurrences are mirrors with an empty placeholder),
/// `$0` as the final stop, and escapes `\$`, `\\`, `\}`.
///
/// Regex transforms (`${1/…/…/}`) are out of scope (P4) and fail loud with
/// `.invalidStop` rather than being silently mangled.
public enum SnippetParser {
    public static func parse(_ body: String) throws -> ParsedSnippet {
        var scanner = Scanner(characters: Array(body))
        let nodes = try scanner.parseNodes(insideBraces: false)

        let finalNodes = containsTabStop(nodes, index: 0) ? nodes : nodes + [.tabStop(index: 0, placeholder: [])]
        return ParsedSnippet(nodes: finalNodes)
    }

    /// Whether `$<index>` occurs anywhere in the tree (mirror-emptying already
    /// happened during parsing; this only answers "is there an explicit occurrence").
    private static func containsTabStop(_ nodes: [SnippetNode], index target: Int) -> Bool {
        nodes.contains { node in
            switch node {
            case .text:
                return false
            case .tabStop(let index, let placeholder):
                return index == target || containsTabStop(placeholder, index: target)
            }
        }
    }

    /// Recursive-descent scanner over a `[Character]` buffer. No regex.
    private struct Scanner {
        let characters: [Character]
        var position = 0

        /// Index -> placeholder nodes for the primary (first) occurrence of each tab stop index.
        /// Shared across the whole scan (a class would work too, but threading an inout dictionary
        /// through the recursive parse keeps this a value type).
        var primaryPlaceholders: [Int: [SnippetNode]] = [:]

        init(characters: [Character]) {
            self.characters = characters
        }

        var isAtEnd: Bool { position >= characters.count }

        func peek() -> Character? {
            isAtEnd ? nil : characters[position]
        }

        mutating func advance() -> Character {
            let c = characters[position]
            position += 1
            return c
        }

        /// Parses a run of nodes. When `insideBraces` is true, stops at an
        /// unescaped `}` (leaving it unconsumed) instead of running to end-of-input.
        mutating func parseNodes(insideBraces: Bool) throws -> [SnippetNode] {
            var nodes: [SnippetNode] = []
            var text = ""

            func flushText() {
                if !text.isEmpty {
                    nodes.append(.text(text))
                    text = ""
                }
            }

            while let c = peek() {
                if insideBraces && c == "}" {
                    break
                }

                if c == "\\" {
                    position += 1
                    guard let escaped = peek() else {
                        // Trailing backslash with nothing after it: treat literally.
                        text.append("\\")
                        break
                    }
                    switch escaped {
                    case "$", "\\", "}":
                        text.append(escaped)
                        position += 1
                    default:
                        // Unknown escape: keep the backslash and the character as-is.
                        text.append("\\")
                    }
                    continue
                }

                if c == "$" {
                    flushText()
                    let node = try parseTabStop()
                    nodes.append(node)
                    continue
                }

                text.append(advance())
            }

            flushText()
            return nodes
        }

        /// Called with `peek() == "$"`. Parses `$N` or `${N:...}`.
        mutating func parseTabStop() throws -> SnippetNode {
            position += 1 // consume '$'

            if peek() == "{" {
                position += 1 // consume '{'
                let index = try parseIndex()

                guard let next = peek() else { throw SnippetParseError.unbalancedBrace }

                var placeholder: [SnippetNode] = []
                if next == ":" {
                    position += 1 // consume ':'
                    placeholder = try parseNodes(insideBraces: true)
                } else if next == "/" {
                    throw SnippetParseError.invalidStop
                } else if next != "}" {
                    throw SnippetParseError.unbalancedBrace
                }

                guard peek() == "}" else { throw SnippetParseError.unbalancedBrace }
                position += 1 // consume '}'

                return resolveTabStop(index: index, placeholder: placeholder)
            }

            // Bare `$N`
            let index = try parseIndex()
            return resolveTabStop(index: index, placeholder: [])
        }

        /// Records the primary placeholder the first time an index is seen;
        /// empties the placeholder for every later (mirror) occurrence.
        mutating func resolveTabStop(index: Int, placeholder: [SnippetNode]) -> SnippetNode {
            if primaryPlaceholders[index] != nil {
                return .tabStop(index: index, placeholder: [])
            }
            primaryPlaceholders[index] = placeholder
            return .tabStop(index: index, placeholder: placeholder)
        }

        /// Parses one-or-more digits into an Int. Throws `.invalidStop` if
        /// there's no digit where one is expected.
        mutating func parseIndex() throws -> Int {
            var digits = ""
            while let c = peek(), c.isNumber {
                digits.append(advance())
            }
            guard let index = Int(digits) else { throw SnippetParseError.invalidStop }
            return index
        }
    }
}
