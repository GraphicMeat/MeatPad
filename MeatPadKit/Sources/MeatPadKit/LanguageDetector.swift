import Foundation

/// Detects a `Language` from a filename and/or file contents.
/// Priority: modeline (vim/emacs) > shebang > extension.
public enum LanguageDetector {

    /// Aliases for modeline tokens that don't spell the language id exactly:
    /// vim's default filetype for shell scripts is "sh", and Emacs mode names
    /// are "c++-mode" / "js-mode" rather than "cpp-mode" / "javascript-mode".
    private static let aliases: [String: String] = [
        "sh": "bash",
        "c++": "cpp",
        "js": "javascript",
    ]

    public static func detect(filename: String?, contents: String) -> Language? {
        if let language = detectModeline(contents: contents) { return language }
        if let language = detectShebang(contents: contents) { return language }
        if let filename, let language = detectExtension(filename: filename) { return language }
        return nil
    }

    // MARK: - Modeline

    private static func detectModeline(contents: String) -> Language? {
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        // A trailing "\n" produces a phantom empty final element that isn't a real line.
        if contents.hasSuffix("\n") { lines.removeLast() }
        guard !lines.isEmpty else { return nil }

        let headCount = min(5, lines.count)
        let head = lines[0..<headCount]
        let tailStart = max(headCount, lines.count - 5)
        let tail = lines[tailStart...]

        for line in head + tail {
            if let language = vimModeline(in: String(line)) ?? emacsModeline(in: String(line)) {
                return language
            }
        }
        return nil
    }

    private static func vimModeline(in line: String) -> Language? {
        guard let vimRange = line.range(of: "vim:", options: .caseInsensitive) else { return nil }
        let rest = line[vimRange.upperBound...]
        for key in ["filetype=", "ft="] {
            guard let keyRange = rest.range(of: key, options: .caseInsensitive) else { continue }
            let valueStart = keyRange.upperBound
            let valueEnd = rest[valueStart...].firstIndex(where: { $0.isWhitespace || $0 == ":" }) ?? rest.endIndex
            let token = String(rest[valueStart..<valueEnd])
            if let language = resolveToken(token) { return language }
        }
        return nil
    }

    private static func emacsModeline(in line: String) -> Language? {
        guard let firstMarker = line.range(of: "-*-"),
              let secondMarker = line.range(of: "-*-", range: firstMarker.upperBound..<line.endIndex)
        else { return nil }
        let body = line[firstMarker.upperBound..<secondMarker.lowerBound]
        guard let modeRange = body.range(of: "mode:", options: .caseInsensitive) else { return nil }
        let valueStart = body[modeRange.upperBound...].drop(while: { $0.isWhitespace }).startIndex
        let valueEnd = body[valueStart...].firstIndex(where: { $0 == ";" }) ?? body.endIndex
        let token = String(body[valueStart..<valueEnd]).trimmingCharacters(in: .whitespaces)
        return resolveToken(token)
    }

    /// Resolves a modeline mode/filetype token (e.g. "Python", "c++-mode") to a `Language`.
    private static func resolveToken(_ rawToken: String) -> Language? {
        var token = rawToken.lowercased().trimmingCharacters(in: .whitespaces)
        if token.hasSuffix("-mode") {
            token.removeLast("-mode".count)
        }
        if let language = Languages.byID(token) { return language }
        if let aliased = aliases[token] { return Languages.byID(aliased) }
        return nil
    }

    // MARK: - Shebang

    private static func detectShebang(contents: String) -> Language? {
        guard let firstLine = contents.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first,
              firstLine.hasPrefix("#!")
        else { return nil }

        let path = firstLine.dropFirst(2).trimmingCharacters(in: .whitespaces)
        let tokens = path.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let interpreterPath = tokens.first else { return nil }
        var interpreter = (interpreterPath as NSString).lastPathComponent
        // "#!/usr/bin/env python3" — the real interpreter is the token after `env`.
        if interpreter == "env", tokens.count > 1 {
            interpreter = tokens[1]
        }
        return matchShebang(interpreter)
    }

    private static func matchShebang(_ interpreter: String) -> Language? {
        let stripped = stripTrailingVersion(interpreter)
        for language in Languages.all {
            if language.shebangs.contains(interpreter) || language.shebangs.contains(stripped) {
                return language
            }
        }
        return nil
    }

    private static func stripTrailingVersion(_ token: String) -> String {
        var chars = Substring(token)
        while let last = chars.last, last.isNumber || last == "." {
            chars.removeLast()
        }
        return String(chars)
    }

    // MARK: - Extension

    private static func detectExtension(filename: String) -> Language? {
        let name = (filename as NSString).lastPathComponent
        guard let dotIndex = name.lastIndex(of: "."), dotIndex != name.startIndex else { return nil }
        let ext = name[name.index(after: dotIndex)...].lowercased()
        guard !ext.isEmpty else { return nil }
        return Languages.all.first { $0.extensions.contains(ext) }
    }
}
