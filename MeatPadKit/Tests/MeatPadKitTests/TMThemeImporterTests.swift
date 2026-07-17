import XCTest
@testable import MeatPadKit

final class TMThemeImporterTests: XCTestCase {

    /// A minimal tmTheme fixture covering: name, scopeless editor-color settings,
    /// a longest-prefix collision (`constant.numeric` vs `constant`), a comma-separated
    /// multi-scope entry, and an unmapped scope that should be dropped.
    private func fixture(name: String = "My Cool Theme") -> Data {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>name</key>
            <string>\(name)</string>
            <key>settings</key>
            <array>
                <dict>
                    <key>settings</key>
                    <dict>
                        <key>background</key>
                        <string>#1E1E1E</string>
                        <key>foreground</key>
                        <string>#D4D4D4</string>
                        <key>caret</key>
                        <string>#FFFFFF</string>
                        <key>selection</key>
                        <string>#264F78</string>
                        <key>lineHighlight</key>
                        <string>#2A2A2A</string>
                    </dict>
                </dict>
                <dict>
                    <key>scope</key>
                    <string>constant.numeric</string>
                    <key>settings</key>
                    <dict>
                        <key>foreground</key>
                        <string>#B5CEA8</string>
                    </dict>
                </dict>
                <dict>
                    <key>scope</key>
                    <string>constant</string>
                    <key>settings</key>
                    <dict>
                        <key>foreground</key>
                        <string>#4FC1FF</string>
                    </dict>
                </dict>
                <dict>
                    <key>scope</key>
                    <string>comment, string.quoted</string>
                    <key>settings</key>
                    <dict>
                        <key>foreground</key>
                        <string>#6A9955</string>
                    </dict>
                </dict>
                <dict>
                    <key>scope</key>
                    <string>totally.unknown.scope</string>
                    <key>settings</key>
                    <dict>
                        <key>foreground</key>
                        <string>#FF00FF</string>
                    </dict>
                </dict>
            </array>
        </dict>
        </plist>
        """
        return Data(xml.utf8)
    }

    // MARK: - name

    func testImportsThemeName() throws {
        let theme = try TMThemeImporter.importTheme(data: fixture(name: "My Cool Theme"))
        XCTAssertEqual(theme.name, "My Cool Theme")
    }

    func testMissingNameFallsBackToImportedTheme() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>settings</key>
            <array>
                <dict>
                    <key>settings</key>
                    <dict>
                        <key>background</key>
                        <string>#000000</string>
                        <key>foreground</key>
                        <string>#FFFFFF</string>
                    </dict>
                </dict>
            </array>
        </dict>
        </plist>
        """
        let theme = try TMThemeImporter.importTheme(data: Data(xml.utf8))
        XCTAssertEqual(theme.name, "Imported Theme")
    }

    // MARK: - id

    func testImportGeneratesUserPrefixedID() throws {
        let theme = try TMThemeImporter.importTheme(data: fixture())
        XCTAssertTrue(theme.id.hasPrefix("user-"))
    }

    func testTwoImportsProduceDifferentIDs() throws {
        let a = try TMThemeImporter.importTheme(data: fixture())
        let b = try TMThemeImporter.importTheme(data: fixture())
        XCTAssertNotEqual(a.id, b.id)
    }

    // MARK: - scopeless editor colors

    func testEditorColorsComeFromScopelessSettings() throws {
        let theme = try TMThemeImporter.importTheme(data: fixture())
        XCTAssertEqual(theme.editorBackground, RGBAColor(hex: "#1E1E1E")!)
        XCTAssertEqual(theme.editorForeground, RGBAColor(hex: "#D4D4D4")!)
        XCTAssertEqual(theme.caret, RGBAColor(hex: "#FFFFFF")!)
        XCTAssertEqual(theme.selection, RGBAColor(hex: "#264F78")!)
        XCTAssertEqual(theme.currentLine, RGBAColor(hex: "#2A2A2A")!)
    }

    // MARK: - isDark derivation

    func testDarkBackgroundYieldsIsDarkTrue() throws {
        let theme = try TMThemeImporter.importTheme(data: fixture())
        XCTAssertTrue(theme.isDark)
    }

    func testLightBackgroundYieldsIsDarkFalse() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>name</key>
            <string>Light</string>
            <key>settings</key>
            <array>
                <dict>
                    <key>settings</key>
                    <dict>
                        <key>background</key>
                        <string>#FFFFFF</string>
                        <key>foreground</key>
                        <string>#000000</string>
                    </dict>
                </dict>
            </array>
        </dict>
        </plist>
        """
        let theme = try TMThemeImporter.importTheme(data: Data(xml.utf8))
        XCTAssertFalse(theme.isDark)
    }

    // MARK: - scope -> capture mapping

    func testLongestPrefixWinsConstantNumericOverConstant() throws {
        let theme = try TMThemeImporter.importTheme(data: fixture())
        XCTAssertEqual(theme.tokenColors["number"], RGBAColor(hex: "#B5CEA8")!)
        XCTAssertEqual(theme.tokenColors["constant"], RGBAColor(hex: "#4FC1FF")!)
    }

    func testCommaSeparatedMultiScopeEntryMapsAllParts() throws {
        let theme = try TMThemeImporter.importTheme(data: fixture())
        XCTAssertEqual(theme.tokenColors["comment"], RGBAColor(hex: "#6A9955")!)
        XCTAssertEqual(theme.tokenColors["string"], RGBAColor(hex: "#6A9955")!)
    }

    func testUnmappedScopeIsDropped() throws {
        let theme = try TMThemeImporter.importTheme(data: fixture())
        XCTAssertFalse(theme.tokenColors.values.contains(RGBAColor(hex: "#FF00FF")!))
        // Exactly the four mappable captures should be present: number, constant, comment, string.
        XCTAssertEqual(theme.tokenColors.count, 4)
    }

    func testSpaceOnlyMultiScopeEntryMapsAllParts() throws {
        // "keyword.operator storage.type" — space-separated, no comma at all.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>name</key>
            <string>Space Scopes</string>
            <key>settings</key>
            <array>
                <dict>
                    <key>settings</key>
                    <dict>
                        <key>background</key>
                        <string>#000000</string>
                        <key>foreground</key>
                        <string>#FFFFFF</string>
                    </dict>
                </dict>
                <dict>
                    <key>scope</key>
                    <string>keyword.operator storage.type</string>
                    <key>settings</key>
                    <dict>
                        <key>foreground</key>
                        <string>#AAAAAA</string>
                    </dict>
                </dict>
            </array>
        </dict>
        </plist>
        """
        let theme = try TMThemeImporter.importTheme(data: Data(xml.utf8))
        XCTAssertEqual(theme.tokenColors["operator"], RGBAColor(hex: "#AAAAAA")!)
        XCTAssertEqual(theme.tokenColors["type"], RGBAColor(hex: "#AAAAAA")!)
    }

    func testEntryWithGarbageHexIsDropped() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>name</key>
            <string>Garbage Hex</string>
            <key>settings</key>
            <array>
                <dict>
                    <key>settings</key>
                    <dict>
                        <key>background</key>
                        <string>#000000</string>
                        <key>foreground</key>
                        <string>#FFFFFF</string>
                    </dict>
                </dict>
                <dict>
                    <key>scope</key>
                    <string>keyword</string>
                    <key>settings</key>
                    <dict>
                        <key>foreground</key>
                        <string>not-a-hex-color</string>
                    </dict>
                </dict>
                <dict>
                    <key>scope</key>
                    <string>string</string>
                    <key>settings</key>
                    <dict>
                        <key>foreground</key>
                        <string>#6A9955</string>
                    </dict>
                </dict>
            </array>
        </dict>
        </plist>
        """
        let theme = try TMThemeImporter.importTheme(data: Data(xml.utf8))
        XCTAssertNil(theme.tokenColors["keyword"])
        XCTAssertEqual(theme.tokenColors["string"], RGBAColor(hex: "#6A9955")!)
        XCTAssertEqual(theme.tokenColors.count, 1)
    }

    // MARK: - errors

    func testGarbageDataThrowsNotAPlist() {
        let garbage = Data("not a plist at all {{{".utf8)
        XCTAssertThrowsError(try TMThemeImporter.importTheme(data: garbage)) { error in
            XCTAssertEqual(error as? TMThemeImportError, .notAPlist)
        }
    }

    func testMissingSettingsArrayThrowsMissingSettings() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>name</key>
            <string>No Settings</string>
        </dict>
        </plist>
        """
        XCTAssertThrowsError(try TMThemeImporter.importTheme(data: Data(xml.utf8))) { error in
            XCTAssertEqual(error as? TMThemeImportError, .missingSettings)
        }
    }

    func testValidPlistWithNonDictRootThrowsNotAPlist() {
        // Well-formed plist XML, but the root is an array, not a dict.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <array>
            <string>not a theme dict</string>
        </array>
        </plist>
        """
        XCTAssertThrowsError(try TMThemeImporter.importTheme(data: Data(xml.utf8))) { error in
            XCTAssertEqual(error as? TMThemeImportError, .notAPlist)
        }
    }
}
