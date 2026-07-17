import Foundation

public enum TMThemeImportError: Error, Equatable {
    case notAPlist
    case missingSettings
}

/// Imports TextMate `.tmTheme` plists into a `Theme`.
public enum TMThemeImporter {

    /// `settings[0]` (no `scope`) supplies editor chrome colors; every later entry maps
    /// its `scope` (split on `,`/` `) through `scopeToCapture` via longest-prefix match.
    public static func importTheme(data: Data) throws -> Theme {
        guard
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let root = plist as? [String: Any]
        else {
            throw TMThemeImportError.notAPlist
        }
        guard
            let settingsArray = root["settings"] as? [[String: Any]],
            let globalEntry = settingsArray.first,
            globalEntry["scope"] == nil,
            let globalSettings = globalEntry["settings"] as? [String: Any]
        else {
            throw TMThemeImportError.missingSettings
        }

        func color(_ key: String, fallback: RGBAColor) -> RGBAColor {
            guard let hex = globalSettings[key] as? String, let color = RGBAColor(hex: hex) else {
                return fallback
            }
            return color
        }

        let background = color("background", fallback: RGBAColor(r: 0, g: 0, b: 0))
        let foreground = color("foreground", fallback: RGBAColor(r: 1, g: 1, b: 1))
        let caret = color("caret", fallback: foreground)
        let selection = color("selection", fallback: background)
        let currentLine = color("lineHighlight", fallback: background)

        var tokenColors: [String: RGBAColor] = [:]
        for entry in settingsArray.dropFirst() {
            guard
                let scope = entry["scope"] as? String,
                let settings = entry["settings"] as? [String: Any],
                let hex = settings["foreground"] as? String,
                let color = RGBAColor(hex: hex)
            else { continue }

            for part in scope.split(whereSeparator: { $0 == "," || $0 == " " }) {
                guard let capture = capture(forScope: String(part)) else { continue }
                tokenColors[capture] = color
            }
        }

        return Theme(
            id: "user-" + UUID().uuidString,
            name: (root["name"] as? String) ?? "Imported Theme",
            isDark: luminance(of: background) < 0.5,
            editorBackground: background,
            editorForeground: foreground,
            currentLine: currentLine,
            selection: selection,
            caret: caret,
            gutterForeground: foreground,
            tokenColors: tokenColors
        )
    }

    private static func luminance(of color: RGBAColor) -> Double {
        0.299 * color.r + 0.587 * color.g + 0.114 * color.b
    }

    /// Longest dotted-prefix match against `scopeToCapture` (order-independent: the
    /// longest matching prefix wins regardless of table position).
    private static func capture(forScope scope: String) -> String? {
        var best: (prefix: String, capture: String)?
        for entry in scopeToCapture where scope == entry.prefix || scope.hasPrefix(entry.prefix + ".") {
            if best == nil || entry.prefix.count > best!.prefix.count {
                best = entry
            }
        }
        return best?.capture
    }

    static let scopeToCapture: [(prefix: String, capture: String)] = [
        ("comment", "comment"),
        ("string", "string"),
        ("constant.numeric", "number"),
        ("constant.character", "constant"),
        ("constant", "constant"),
        ("keyword.operator", "operator"),
        ("keyword", "keyword"),
        ("storage.type", "type"),
        ("storage", "keyword"),
        ("entity.name.function", "function"),
        ("entity.name.type", "type"),
        ("entity.name.tag", "tag"),
        ("entity.other.attribute-name", "attribute"),
        ("variable.parameter", "variable.parameter"),
        ("variable", "variable"),
        ("support.function", "function"),
        ("support.type", "type"),
        ("punctuation", "punctuation"),
        ("markup.heading", "keyword"),
        ("markup.italic", "comment"),
        ("invalid", "error"),
    ]
}
