import XCTest
@testable import MeatPadKit

final class FileTreeShortcutTests: XCTestCase {

    func testDisplayOrdersModifiersControlOptionShiftCommandThenKey() {
        let shortcut = FileTreeShortcut(key: "c", modifiers: [.command, .shift, .option])
        XCTAssertEqual(shortcut.display, "⌥⇧⌘C")
    }

    func testParseRoundTripsTheDisplayForm() {
        for text in ["⌥⌘R", "⌥⇧⌘C", "⌘⌫", "↩", "⌃⌘X"] {
            XCTAssertEqual(FileTreeShortcut(display: text)?.display, text, text)
        }
    }

    func testParseIgnoresModifierOrder() {
        XCTAssertEqual(FileTreeShortcut(display: "⌘⇧⌥C"), FileTreeShortcut(display: "⌥⇧⌘C"))
    }

    func testParseRejectsEmptyModifierOnlyAndMultiKeyText() {
        XCTAssertNil(FileTreeShortcut(display: ""))
        XCTAssertNil(FileTreeShortcut(display: "⌘"))
        XCTAssertNil(FileTreeShortcut(display: "⌘XY"))
    }

    func testKeyIsStoredLowercase() {
        XCTAssertEqual(FileTreeShortcut(display: "⌘X")?.key, "x")
    }
}

final class FileTreeMenuConfigTests: XCTestCase {

    func testDefaultsMatchVSCode() {
        let config = FileTreeMenuConfig()
        XCTAssertTrue(config.showIcons)
        XCTAssertEqual(config.shortcut(for: .revealInFinder)?.display, "⌥⌘R")
        XCTAssertEqual(config.shortcut(for: .findInFolder)?.display, "⌥⇧F")
        XCTAssertEqual(config.shortcut(for: .cut)?.display, "⌘X")
        XCTAssertEqual(config.shortcut(for: .copy)?.display, "⌘C")
        XCTAssertEqual(config.shortcut(for: .paste)?.display, "⌘V")
        XCTAssertEqual(config.shortcut(for: .copyPath)?.display, "⌥⌘C")
        XCTAssertEqual(config.shortcut(for: .copyRelativePath)?.display, "⌥⇧⌘C")
        XCTAssertEqual(config.shortcut(for: .rename)?.display, "↩")
        XCTAssertEqual(config.shortcut(for: .delete)?.display, "⌘⌫")
        XCTAssertNil(config.shortcut(for: .newFile))
        XCTAssertTrue(FileTreeAction.allCases.allSatisfy(config.isVisible))
    }

    func testOverrideReplacesTheDefaultShortcut() {
        var config = FileTreeMenuConfig()
        config.setShortcut(FileTreeShortcut(display: "⌘D"), for: .copy)
        XCTAssertEqual(config.shortcut(for: .copy)?.display, "⌘D")
    }

    func testClearingRemovesEvenADefaultShortcut() {
        var config = FileTreeMenuConfig()
        config.setShortcut(nil, for: .copy)
        XCTAssertNil(config.shortcut(for: .copy))
    }

    func testSettingTheDefaultBackDropsTheOverride() {
        var config = FileTreeMenuConfig()
        config.setShortcut(FileTreeShortcut(display: "⌘D"), for: .copy)
        config.setShortcut(FileTreeShortcut(display: "⌘C"), for: .copy)
        XCTAssertTrue(config.shortcutOverrides.isEmpty)
    }

    func testHiddenActionsAreNotVisible() {
        var config = FileTreeMenuConfig()
        config.setVisible(false, for: .delete)
        XCTAssertFalse(config.isVisible(.delete))
        XCTAssertTrue(config.isVisible(.rename))
        config.setVisible(true, for: .delete)
        XCTAssertTrue(config.isVisible(.delete))
    }

    func testJSONRoundTrip() throws {
        var config = FileTreeMenuConfig()
        config.showIcons = false
        config.setVisible(false, for: .openInTerminal)
        config.setShortcut(FileTreeShortcut(display: "⌘D"), for: .copy)
        config.setShortcut(nil, for: .rename)
        let decoded = FileTreeMenuConfig.decode(try config.encoded())
        XCTAssertEqual(decoded, config)
    }

    func testDecodeOfGarbageOrNothingFallsBackToDefaults() {
        XCTAssertEqual(FileTreeMenuConfig.decode(nil), FileTreeMenuConfig())
        XCTAssertEqual(FileTreeMenuConfig.decode(Data("not json".utf8)), FileTreeMenuConfig())
    }

    func testDecodeSkipsUnknownActionNames() {
        let json = #"{"showIcons":true,"hidden":["delete","teleport"],"shortcutOverrides":{}}"#
        let config = FileTreeMenuConfig.decode(Data(json.utf8))
        XCTAssertFalse(config.isVisible(.delete))
        XCTAssertTrue(config.isVisible(.rename))
    }
}

final class FileTreeMenuModelTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/work/proj", isDirectory: true)

    private func context(_ path: String, isDirectory: Bool, clipboard: Bool = false) -> FileTreeMenuContext {
        FileTreeMenuContext(
            target: URL(fileURLWithPath: "/work/proj/" + path, isDirectory: isDirectory),
            isDirectory: isDirectory, root: root, clipboardHasFiles: clipboard
        )
    }

    private func shape(_ entries: [FileTreeMenuEntry]) -> [String] {
        entries.map {
            switch $0 {
            case .separator: return "-"
            case .item(let item): return item.action.rawValue
            }
        }
    }

    func testFileMenuHasTheVSCodeOrderAndSeparators() {
        let entries = FileTreeMenu.entries(for: context("src/main.swift", isDirectory: false), config: FileTreeMenuConfig())
        XCTAssertEqual(shape(entries), [
            "newFile", "newFolder", "-",
            "revealInFinder", "openInPreview", "openInTerminal", "-",
            "findInFolder", "-",
            "cut", "copy", "paste", "-",
            "copyPath", "copyRelativePath", "-",
            "rename", "delete",
        ])
    }

    func testFolderMenuOmitsOpenInPreview() {
        let entries = FileTreeMenu.entries(for: context("src", isDirectory: true), config: FileTreeMenuConfig())
        XCTAssertFalse(shape(entries).contains("openInPreview"))
        XCTAssertTrue(shape(entries).contains("openInTerminal"))
    }

    func testHidingAWholeGroupDropsItsSeparatorToo() {
        var config = FileTreeMenuConfig()
        config.setVisible(false, for: .findInFolder)
        let names = shape(FileTreeMenu.entries(for: context("a.txt", isDirectory: false), config: config))
        XCTAssertFalse(names.contains("findInFolder"))
        XCTAssertFalse(zip(names, names.dropFirst()).contains { $0 == "-" && $1 == "-" })
    }

    func testNoLeadingOrTrailingSeparator() {
        var config = FileTreeMenuConfig()
        config.setVisible(false, for: .newFile)
        config.setVisible(false, for: .newFolder)
        config.setVisible(false, for: .rename)
        config.setVisible(false, for: .delete)
        let names = shape(FileTreeMenu.entries(for: context("a.txt", isDirectory: false), config: config))
        XCTAssertNotEqual(names.first, "-")
        XCTAssertNotEqual(names.last, "-")
    }

    func testEverythingHiddenGivesAnEmptyMenu() {
        var config = FileTreeMenuConfig()
        for action in FileTreeAction.allCases { config.setVisible(false, for: action) }
        XCTAssertTrue(FileTreeMenu.entries(for: context("a.txt", isDirectory: false), config: config).isEmpty)
    }

    func testPasteIsDisabledUntilTheClipboardHasFiles() {
        func paste(_ clipboard: Bool) -> FileTreeMenuItem? {
            FileTreeMenu.entries(for: context("a.txt", isDirectory: false, clipboard: clipboard), config: FileTreeMenuConfig())
                .compactMap { if case .item(let i) = $0, i.action == .paste { return i } else { return nil } }.first
        }
        XCTAssertEqual(paste(false)?.isEnabled, false)
        XCTAssertEqual(paste(true)?.isEnabled, true)
    }

    func testCopyPathItemsShowWhatTheyWillCopy() {
        let entries = FileTreeMenu.entries(for: context("src/main.swift", isDirectory: false), config: FileTreeMenuConfig())
        let items = entries.compactMap { entry -> FileTreeMenuItem? in
            if case .item(let item) = entry { return item } else { return nil }
        }
        XCTAssertEqual(items.first { $0.action == .copyPath }?.subtitle, "/work/proj/src/main.swift")
        XCTAssertEqual(items.first { $0.action == .copyRelativePath }?.subtitle, "src/main.swift")
        XCTAssertNil(items.first { $0.action == .copy }?.subtitle)
    }

    func testItemsCarryTheConfiguredShortcut() {
        var config = FileTreeMenuConfig()
        config.setShortcut(FileTreeShortcut(display: "⌘D"), for: .copy)
        config.setShortcut(nil, for: .delete)
        let items = FileTreeMenu.entries(for: context("a.txt", isDirectory: false), config: config)
            .compactMap { entry -> FileTreeMenuItem? in if case .item(let i) = entry { return i } else { return nil } }
        XCTAssertEqual(items.first { $0.action == .copy }?.shortcut?.display, "⌘D")
        XCTAssertNil(items.first { $0.action == .delete }?.shortcut)
        XCTAssertEqual(items.first { $0.action == .cut }?.shortcut?.display, "⌘X")
    }
}
