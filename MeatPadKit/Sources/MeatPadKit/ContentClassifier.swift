import Foundation

/// Guesses a `Language` from raw contents alone — the last-resort detection tier for
/// filename-less buffers (notes) and unknown extensions. Weighted regex scoring per
/// language; the winner needs a minimum score AND a clear margin over the runner-up,
/// otherwise nil: plain text beats a wrong guess.
public enum ContentClassifier {

    private struct Pattern {
        let regex: NSRegularExpression
        let weight: Int
    }

    /// Only the head of the buffer carries signal worth paying for.
    private static let scanCap = 8 * 1024
    /// A single pattern can't win alone no matter how often it repeats.
    private static let occurrenceCap = 3
    private static let minimumScore = 4
    private static let minimumMargin = 2

    public static func classify(_ contents: String) -> Language? {
        let sample = String(contents.prefix(scanCap))
        guard !sample.isEmpty else { return nil }
        let range = NSRange(sample.startIndex..., in: sample)

        var scores: [(id: String, score: Int)] = []
        for (id, patterns) in tables {
            var score = 0
            for pattern in patterns {
                let count = pattern.regex.numberOfMatches(in: sample, range: range)
                score += pattern.weight * min(count, occurrenceCap)
            }
            if score > 0 { scores.append((id: id, score: score)) }
        }

        scores.sort { $0.score > $1.score }
        guard let best = scores.first, best.score >= minimumScore else { return nil }
        if scores.count > 1, best.score - scores[1].score < minimumMargin { return nil }
        return Languages.byID(best.id)
    }

    /// Force-try is deliberate: patterns are compile-time constants, a typo should
    /// crash the test suite loudly rather than silently score zero.
    private static func p(_ pattern: String, _ weight: Int) -> Pattern {
        Pattern(
            regex: try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
            weight: weight
        )
    }

    /// languageID -> weighted signals. Weights 1-3: 3 = near-unique to the language,
    /// 1 = weak/shared hint. Markdown is absent on purpose (no grammar wired).
    private static let tables: [String: [Pattern]] = [
        "swift": [
            p(#"\bfunc\s+\w+\s*\("#, 3),
            p(#"\bguard\s"#, 3),
            p(#"\bimport\s+(Foundation|SwiftUI|AppKit|UIKit)\b"#, 3),
            p(#"\bstruct\s+\w+\s*[:{]"#, 2),
            p(#"\b(let|var)\s+\w+\s*="#, 1),
        ],
        "python": [
            p(#"^\s*def\s+\w+\s*\(.*\)\s*:"#, 3),
            p(#"^\s*(import|from)\s+\w+"#, 2),
            p(#"^\s*class\s+\w+.*:\s*$"#, 2),
            p(#"\bself\."#, 1),
            p(#"\bprint\("#, 1),
        ],
        "ruby": [
            p(#"^\s*end\s*$"#, 2),
            p(#"\bputs\b"#, 2),
            p(#"\brequire\s+['"]"#, 2),
            p(#"\.each\s+do\b"#, 2),
            p(#"^\s*def\s+\w+"#, 1),
        ],
        "javascript": [
            p(#"\bconst\s+\w+\s*="#, 2),
            p(#"\bfunction\s+\w+\s*\("#, 2),
            p(#"\bconsole\.log\("#, 2),
            p(#"=>"#, 1),
            p(#"==="#, 1),
            p(#"\brequire\("#, 1),
            p(#"\b(let|var)\s+\w+\s*="#, 1),
        ],
        // TS-only signals, no JS overlap: plain JS must score 0 here so it stays JS.
        "typescript": [
            p(#":\s*(string|number|boolean|void|any)\b"#, 3),
            p(#"\binterface\s+\w+\s*\{"#, 3),
            p(#"\btype\s+\w+\s*="#, 2),
            p(#"\bexport\s+(interface|type)\b"#, 2),
        ],
        "tsx": [
            p(#"return\s*\(\s*<"#, 3),
            p(#"<[A-Z]\w*[\s/>]"#, 2),
            p(#":\s*(string|number|boolean)\b"#, 2),
            p(#"/>"#, 2),
            p(#"=>\s*\{"#, 1),
        ],
        "json": [
            p(#"\A\s*[\{\[]"#, 2),
            p(#""[\w-]+"\s*:"#, 2),
            p(#":\s*(true|false|null|-?\d)"#, 1),
        ],
        "html": [
            p(#"<!DOCTYPE"#, 3),
            p(#"</?(div|span|html|head|body|p|a|ul|li|title)\b"#, 2),
            p(#"<\w+\s+class=""#, 2),
        ],
        "css": [
            p(#"^\s*\.[\w-]+\s*\{"#, 3),
            p(#"@media\b"#, 3),
            p(#"^\s*[\w-]+\s*:\s*[^;{}]+;\s*$"#, 2),
            p(#"^\s*#[\w-]+\s*\{"#, 2),
        ],
        // Top-level "key: value" / "key:" lines only; the (\s+\S.*)? alternative forces
        // whitespace after the colon so "https://…" never counts. Key must start lowercase
        // (YAML convention) so a capitalized prose sentence like "Note: remember the milk."
        // doesn't read as a key line.
        "yaml": [
            p(#"^[a-z][\w-]*:(\s+\S.*)?\s*$"#, 2),
            p(#"^\s*-\s+\S"#, 1),
            p(#"^---\s*$"#, 3),
        ],
        "bash": [
            p(#"\b(done|fi|esac|elif)\b"#, 2),
            p(#"\becho\s"#, 2),
            p(#"^\s*\w+\(\)\s*\{"#, 2),
            p(#"\[\[\s"#, 2),
            p(#"\$\{?\w+"#, 1),
        ],
        "go": [
            p(#"^package\s+\w+$"#, 3),
            p(#":="#, 3),
            p(#"\bfmt\.\w+\("#, 3),
            p(#"\bfunc\s+\w+\s*\("#, 1),
        ],
        "rust": [
            p(#"\bfn\s+\w+\s*\("#, 3),
            p(#"\blet\s+mut\s"#, 3),
            p(#"\bprintln!\("#, 3),
            p(#"\bimpl\s+\w+"#, 2),
            p(#"::<?\w"#, 1),
        ],
        // <name.h> is C's include shape; bare <name> is C++'s (see cpp below).
        "c": [
            p(#"#include\s*<\w+\.h>"#, 3),
            p(#"\bprintf\s*\("#, 2),
            p(#"\bint\s+main\s*\("#, 2),
            p(#"\bmalloc\s*\("#, 2),
        ],
        "cpp": [
            p(#"\bstd::"#, 3),
            p(#"\btemplate\s*<"#, 3),
            p(#"#include\s*<\w+>"#, 2),
            p(#"\bcout\b"#, 2),
            p(#"\bnullptr\b"#, 2),
            p(#"\bnamespace\s+\w+"#, 2),
        ],
    ]
}
