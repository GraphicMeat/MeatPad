import XCTest
@testable import FinderMenuKit

final class FinderMenuConfigTests: XCTestCase {

    // MARK: sanitizedExtension

    func testSanitizedExtensionTrimsAndDropsLeadingDots() {
        XCTAssertEqual(FinderMenuConfig.sanitizedExtension(".md"), "md")
        XCTAssertEqual(FinderMenuConfig.sanitizedExtension(" txt "), "txt")
        XCTAssertEqual(FinderMenuConfig.sanitizedExtension("..json"), "json")
    }

    func testSanitizedExtensionKeepsCase() {
        XCTAssertEqual(FinderMenuConfig.sanitizedExtension("MD"), "MD")
        XCTAssertEqual(FinderMenuConfig.sanitizedExtension("c++"), "c++")
        XCTAssertEqual(FinderMenuConfig.sanitizedExtension("tar_gz-1"), "tar_gz-1")
    }

    func testSanitizedExtensionRejectsAnythingThatIsNotAPlainExtension() {
        for raw in ["", ".", "  ", "a/b", "../x", "a b", "a.b", "é", String(repeating: "a", count: 17)] {
            XCTAssertNil(FinderMenuConfig.sanitizedExtension(raw), "\(raw) should not sanitise")
        }
        XCTAssertEqual(FinderMenuConfig.sanitizedExtension(String(repeating: "a", count: 16)), String(repeating: "a", count: 16))
    }

    // MARK: defaults

    func testDefaultsAreMarkdownThenTextWithStableIDs() {
        let config = FinderMenuConfig()
        XCTAssertEqual(config.actions.map(\.title), ["Markdown", "Text"])
        XCTAssertEqual(config.actions.map(\.fileExtension), ["md", "txt"])
        XCTAssertEqual(config.actions.map(\.isEnabled), [true, true])
        XCTAssertFalse(config.groupInSubmenu)
        XCTAssertEqual(config.afterCreate, .openInMeatPad)
        XCTAssertEqual(FinderMenuConfig.defaultActions.map(\.id), FinderMenuConfig().actions.map(\.id))
        XCTAssertEqual(FinderMenuConfig.defaultsKey, "finder.menu")
    }

    // MARK: decode

    func testDecodeOfNothingGarbageOrAnEmptyObjectIsTheDefaults() {
        XCTAssertEqual(FinderMenuConfig.decode(nil), FinderMenuConfig())
        XCTAssertEqual(FinderMenuConfig.decode(Data("not json".utf8)), FinderMenuConfig())
        XCTAssertEqual(FinderMenuConfig.decode(Data("[1,2]".utf8)), FinderMenuConfig())
        XCTAssertEqual(FinderMenuConfig.decode(Data("{}".utf8)), FinderMenuConfig())
    }

    func testDecodeFillsMissingKeysWithDefaults() {
        let config = FinderMenuConfig.decode(Data(#"{"groupInSubmenu":true}"#.utf8))
        XCTAssertEqual(config.actions, FinderMenuConfig.defaultActions)
        XCTAssertTrue(config.groupInSubmenu)
        XCTAssertEqual(config.afterCreate, .openInMeatPad)
    }

    func testAnUnknownAfterCreateFallsBackWithoutLosingTheRest() {
        let json = #"{"afterCreate":"launchRockets","groupInSubmenu":true,"actions":[{"id":"8F0C3D5E-0000-4000-8000-000000000001","title":"JSON","fileExtension":"json","isEnabled":true}]}"#
        let config = FinderMenuConfig.decode(Data(json.utf8))
        XCTAssertEqual(config.afterCreate, .openInMeatPad)
        XCTAssertTrue(config.groupInSubmenu)
        XCTAssertEqual(config.actions.map(\.title), ["JSON"])
        XCTAssertEqual(config.actions.map(\.fileExtension), ["json"])
    }

    func testAKnownAfterCreateIsRead() {
        let config = FinderMenuConfig.decode(Data(#"{"afterCreate":"showInFinder"}"#.utf8))
        XCTAssertEqual(config.afterCreate, .showInFinder)
        XCTAssertEqual(config.actions, FinderMenuConfig.defaultActions)
    }

    func testAnExplicitlyEmptyActionListStaysEmpty() {
        let config = FinderMenuConfig.decode(Data(#"{"actions":[]}"#.utf8))
        XCTAssertEqual(config.actions, [])
    }

    func testEncodeRoundTripsWithSortedKeys() throws {
        var config = FinderMenuConfig(groupInSubmenu: true, afterCreate: .showInFinder)
        config.actions.append(FinderNewFileAction(title: "JSON", fileExtension: "json", isEnabled: false))
        let data = try config.encoded()
        XCTAssertEqual(FinderMenuConfig.decode(data), config)
        let text = String(decoding: data, as: UTF8.self)
        let actions = try XCTUnwrap(text.range(of: "\"actions\""))
        let afterCreate = try XCTUnwrap(text.range(of: "\"afterCreate\""))
        let group = try XCTUnwrap(text.range(of: "\"groupInSubmenu\""))
        XCTAssertLessThan(actions.lowerBound, afterCreate.lowerBound)
        XCTAssertLessThan(afterCreate.lowerBound, group.lowerBound)
        XCTAssertTrue(text.contains(#""afterCreate":"showInFinder""#), text)
    }

    // MARK: enabledActions

    func testEnabledActionsSkipDisabledBlankAndUnsanitisableOnesAndCleanTheRest() {
        let config = FinderMenuConfig(actions: [
            FinderNewFileAction(title: "  Markdown ", fileExtension: ".md"),
            FinderNewFileAction(title: "Off", fileExtension: "off", isEnabled: false),
            FinderNewFileAction(title: "   ", fileExtension: "blank"),
            FinderNewFileAction(title: "Bad", fileExtension: "a/b"),
            FinderNewFileAction(title: "Text", fileExtension: " TXT "),
        ])
        let enabled = config.enabledActions
        XCTAssertEqual(enabled.map(\.title), ["Markdown", "Text"])
        XCTAssertEqual(enabled.map(\.fileExtension), ["md", "TXT"])
        XCTAssertEqual(enabled.map(\.id), [config.actions[0].id, config.actions[4].id])
    }
}
