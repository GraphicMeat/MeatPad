import XCTest
@testable import MeatPadKit

final class ThemeTests: XCTestCase {

    // MARK: - RGBAColor(hex:)

    func testHexParsesRRGGBB() {
        let color = RGBAColor(hex: "#FF8800")
        XCTAssertNotNil(color)
        XCTAssertEqual(color!.r, 1.0, accuracy: 0.001)
        XCTAssertEqual(color!.g, 0.533, accuracy: 0.01)
        XCTAssertEqual(color!.b, 0.0, accuracy: 0.001)
        XCTAssertEqual(color!.a, 1.0, accuracy: 0.001)
    }

    func testHexParsesRRGGBBAA() {
        let color = RGBAColor(hex: "#FF880080")
        XCTAssertNotNil(color)
        XCTAssertEqual(color!.a, 0.502, accuracy: 0.01)
    }

    func testHexRejectsInvalid() {
        XCTAssertNil(RGBAColor(hex: "not-a-color"))
        XCTAssertNil(RGBAColor(hex: "#FFF"))
        XCTAssertNil(RGBAColor(hex: "#GGHHII"))
        XCTAssertNil(RGBAColor(hex: ""))
    }

    // MARK: - Theme.color(forCapture:)

    private func makeTheme(tokenColors: [String: RGBAColor]) -> Theme {
        Theme(
            id: "test-theme",
            name: "Test Theme",
            isDark: true,
            editorBackground: RGBAColor(r: 0, g: 0, b: 0),
            editorForeground: RGBAColor(r: 1, g: 1, b: 1),
            currentLine: RGBAColor(r: 0.1, g: 0.1, b: 0.1),
            selection: RGBAColor(r: 0.2, g: 0.2, b: 0.2),
            caret: RGBAColor(r: 1, g: 1, b: 1),
            gutterForeground: RGBAColor(r: 0.5, g: 0.5, b: 0.5),
            tokenColors: tokenColors
        )
    }

    func testColorForCaptureFallsBackToPrefix() {
        let theme = makeTheme(tokenColors: ["keyword": RGBAColor(r: 1, g: 0, b: 0)])
        XCTAssertEqual(theme.color(forCapture: "keyword.return"), RGBAColor(r: 1, g: 0, b: 0))
    }

    func testColorForCaptureExactMatchWinsOverPrefix() {
        let theme = makeTheme(tokenColors: [
            "keyword": RGBAColor(r: 1, g: 0, b: 0),
            "keyword.return": RGBAColor(r: 0, g: 1, b: 0),
        ])
        XCTAssertEqual(theme.color(forCapture: "keyword.return"), RGBAColor(r: 0, g: 1, b: 0))
    }

    func testColorForCaptureFallsBackThroughMultipleLevels() {
        let theme = makeTheme(tokenColors: ["punctuation": RGBAColor(r: 0, g: 0, b: 1)])
        XCTAssertEqual(theme.color(forCapture: "punctuation.bracket.open"), RGBAColor(r: 0, g: 0, b: 1))
    }

    func testColorForCaptureUnknownReturnsNil() {
        let theme = makeTheme(tokenColors: ["keyword": RGBAColor(r: 1, g: 0, b: 0)])
        XCTAssertNil(theme.color(forCapture: "totally.unknown.capture"))
    }

    // MARK: - Codable round-trip

    func testThemeRoundTripsThroughJSON() throws {
        let theme = makeTheme(tokenColors: ["string": RGBAColor(r: 0, g: 1, b: 0)])
        let data = try JSONEncoder().encode(theme)
        let decoded = try JSONDecoder().decode(Theme.self, from: data)
        XCTAssertEqual(decoded, theme)
    }

    // MARK: - BuiltinThemes

    func testBuiltinThemesHasAtLeastTwo() {
        XCTAssertGreaterThanOrEqual(BuiltinThemes.all.count, 2)
    }

    func testBuiltinThemesIncludesDefaultDarkAndLight() {
        XCTAssertTrue(BuiltinThemes.defaultDark.isDark)
        XCTAssertFalse(BuiltinThemes.defaultLight.isDark)
        XCTAssertTrue(BuiltinThemes.all.contains(BuiltinThemes.defaultDark))
        XCTAssertTrue(BuiltinThemes.all.contains(BuiltinThemes.defaultLight))
    }

    func testBuiltinThemesCoverRequiredTokenKeys() {
        let requiredKeys: Set<String> = [
            "keyword", "string", "comment", "function", "type", "number",
            "constant", "variable", "property", "operator", "punctuation",
        ]
        for theme in BuiltinThemes.all {
            let missing = requiredKeys.subtracting(theme.tokenColors.keys)
            XCTAssertTrue(missing.isEmpty, "\(theme.id) missing token keys: \(missing)")
        }
    }
}
