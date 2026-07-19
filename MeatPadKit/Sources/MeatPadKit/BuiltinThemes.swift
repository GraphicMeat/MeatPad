import Foundation

/// Built-in, always-available themes shipped with MeatPad.
public enum BuiltinThemes {
    public static let defaultDark = Theme(
        id: "meat-dark",
        name: "Meat Dark",
        isDark: true,
        editorBackground: RGBAColor(hex: "#1E1F22")!,
        editorForeground: RGBAColor(hex: "#D4D4D8")!,
        currentLine: RGBAColor(hex: "#2A2B2E")!,
        selection: RGBAColor(hex: "#3B3D42")!,
        caret: RGBAColor(hex: "#FFFFFF")!,
        gutterForeground: RGBAColor(hex: "#6B6D73")!,
        tokenColors: [
            "keyword": RGBAColor(hex: "#F97583")!,
            "string": RGBAColor(hex: "#9ECBFF")!,
            "comment": RGBAColor(hex: "#6A737D")!,
            "function": RGBAColor(hex: "#B392F0")!,
            "type": RGBAColor(hex: "#FFAB70")!,
            "number": RGBAColor(hex: "#79B8FF")!,
            "constant": RGBAColor(hex: "#79B8FF")!,
            "variable": RGBAColor(hex: "#D4D4D8")!,
            "property": RGBAColor(hex: "#85E89D")!,
            "operator": RGBAColor(hex: "#F97583")!,
            "punctuation": RGBAColor(hex: "#D4D4D8")!,
            "text.title": RGBAColor(hex: "#FFAB70")!,
            "text.emphasis": RGBAColor(hex: "#B392F0")!,
            "text.strong": RGBAColor(hex: "#F97583")!,
            "text.literal": RGBAColor(hex: "#9ECBFF")!,
            "text.reference": RGBAColor(hex: "#85E89D")!,
            "text.uri": RGBAColor(hex: "#6A737D")!,
        ]
    )

    public static let defaultLight = Theme(
        id: "meat-light",
        name: "Meat Light",
        isDark: false,
        editorBackground: RGBAColor(hex: "#FFFFFF")!,
        editorForeground: RGBAColor(hex: "#24292E")!,
        currentLine: RGBAColor(hex: "#F6F8FA")!,
        selection: RGBAColor(hex: "#C8E1FF")!,
        caret: RGBAColor(hex: "#24292E")!,
        gutterForeground: RGBAColor(hex: "#A0A4AB")!,
        tokenColors: [
            "keyword": RGBAColor(hex: "#D73A49")!,
            "string": RGBAColor(hex: "#032F62")!,
            "comment": RGBAColor(hex: "#6A737D")!,
            "function": RGBAColor(hex: "#6F42C1")!,
            "type": RGBAColor(hex: "#E36209")!,
            "number": RGBAColor(hex: "#005CC5")!,
            "constant": RGBAColor(hex: "#005CC5")!,
            "variable": RGBAColor(hex: "#24292E")!,
            "property": RGBAColor(hex: "#22863A")!,
            "operator": RGBAColor(hex: "#D73A49")!,
            "punctuation": RGBAColor(hex: "#24292E")!,
            "text.title": RGBAColor(hex: "#E36209")!,
            "text.emphasis": RGBAColor(hex: "#6F42C1")!,
            "text.strong": RGBAColor(hex: "#D73A49")!,
            "text.literal": RGBAColor(hex: "#032F62")!,
            "text.reference": RGBAColor(hex: "#22863A")!,
            "text.uri": RGBAColor(hex: "#6A737D")!,
        ]
    )

    public static let all: [Theme] = [defaultDark, defaultLight]
}
