import Foundation

/// A color in the sRGB space with straight (non-premultiplied) alpha.
public struct RGBAColor: Codable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// Parses `#RRGGBB` or `#RRGGBBAA` hex strings. Returns nil for anything else.
    public init?(hex: String) {
        var hex = hex
        guard hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        guard hex.count == 6 || hex.count == 8 else { return nil }
        guard let value = UInt32(hex, radix: 16) else { return nil }

        if hex.count == 6 {
            let r = Double((value >> 16) & 0xFF) / 255
            let g = Double((value >> 8) & 0xFF) / 255
            let b = Double(value & 0xFF) / 255
            self.init(r: r, g: g, b: b, a: 1)
        } else {
            let r = Double((value >> 24) & 0xFF) / 255
            let g = Double((value >> 16) & 0xFF) / 255
            let b = Double((value >> 8) & 0xFF) / 255
            let a = Double(value & 0xFF) / 255
            self.init(r: r, g: g, b: b, a: a)
        }
    }
}

/// A syntax + editor color theme. Token colors are keyed by tree-sitter capture name
/// (e.g. "keyword", "string.escape") and resolved via longest-dotted-prefix fallback.
public struct Theme: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var isDark: Bool
    public var editorBackground: RGBAColor
    public var editorForeground: RGBAColor
    public var currentLine: RGBAColor
    public var selection: RGBAColor
    public var caret: RGBAColor
    public var gutterForeground: RGBAColor
    public var tokenColors: [String: RGBAColor]

    public init(
        id: String,
        name: String,
        isDark: Bool,
        editorBackground: RGBAColor,
        editorForeground: RGBAColor,
        currentLine: RGBAColor,
        selection: RGBAColor,
        caret: RGBAColor,
        gutterForeground: RGBAColor,
        tokenColors: [String: RGBAColor]
    ) {
        self.id = id
        self.name = name
        self.isDark = isDark
        self.editorBackground = editorBackground
        self.editorForeground = editorForeground
        self.currentLine = currentLine
        self.selection = selection
        self.caret = caret
        self.gutterForeground = gutterForeground
        self.tokenColors = tokenColors
    }

    /// Resolves a tree-sitter capture name to a color by trying the full capture,
    /// then repeatedly dropping the trailing `.component` until a match is found.
    public func color(forCapture capture: String) -> RGBAColor? {
        var key = Substring(capture)
        while true {
            if let color = tokenColors[String(key)] {
                return color
            }
            guard let dotIndex = key.lastIndex(of: ".") else { return nil }
            key = key[key.startIndex..<dotIndex]
        }
    }
}
