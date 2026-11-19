import XCTest
@testable import FinderMenuKit

final class FinderMenuTests: XCTestCase {

    private let markdown = FinderNewFileAction(title: "Markdown", fileExtension: "md")
    private let text = FinderNewFileAction(title: "Text", fileExtension: "txt")
    private let off = FinderNewFileAction(title: "Off", fileExtension: "off", isEnabled: false)

    // MARK: entries

    func testNothingEnabledMeansNoEntries() {
        XCTAssertEqual(FinderMenu.entries(for: FinderMenuConfig(actions: [])), [])
        XCTAssertEqual(FinderMenu.entries(for: FinderMenuConfig(actions: [off])), [])
        XCTAssertEqual(FinderMenu.entries(for: FinderMenuConfig(actions: [off], groupInSubmenu: true)), [])
    }

    func testFlatEntriesAreNewTitleFileTaggedByEnabledIndex() {
        let config = FinderMenuConfig(actions: [off, markdown, text])
        XCTAssertEqual(FinderMenu.entries(for: config), [
            .item(title: "New Markdown File", tag: 0),
            .item(title: "New Text File", tag: 1),
        ])
    }

    func testTheDefaultMenuIsMarkdownThenText() {
        XCTAssertEqual(FinderMenu.entries(for: FinderMenuConfig()), [
            .item(title: "New Markdown File", tag: 0),
            .item(title: "New Text File", tag: 1),
        ])
    }

    func testGroupedEntriesAreOneNewFileSubmenuOfBareTitles() {
        let config = FinderMenuConfig(actions: [markdown, off, text], groupInSubmenu: true)
        XCTAssertEqual(FinderMenu.submenuTitle, "New File")
        XCTAssertEqual(FinderMenu.entries(for: config), [
            .submenu(title: "New File", items: [
                .item(title: "Markdown", tag: 0),
                .item(title: "Text", tag: 1),
            ]),
        ])
    }

    // MARK: action(forTag:)

    func testTagsIndexIntoTheEnabledActions() {
        let config = FinderMenuConfig(actions: [off, markdown, text])
        XCTAssertEqual(FinderMenu.action(forTag: 0, in: config)?.id, markdown.id)
        XCTAssertEqual(FinderMenu.action(forTag: 1, in: config)?.id, text.id)
    }

    func testOutOfRangeOrNegativeTagsResolveToNothing() {
        let config = FinderMenuConfig(actions: [off, markdown, text])
        XCTAssertNil(FinderMenu.action(forTag: 2, in: config))
        XCTAssertNil(FinderMenu.action(forTag: -1, in: config))
        XCTAssertNil(FinderMenu.action(forTag: 0, in: FinderMenuConfig(actions: [])))
    }

    func testTheResolvedActionCarriesTheSanitisedExtension() {
        let config = FinderMenuConfig(actions: [FinderNewFileAction(title: " Notes ", fileExtension: ".MD ")])
        let action = FinderMenu.action(forTag: 0, in: config)
        XCTAssertEqual(action?.fileExtension, "MD")
        XCTAssertEqual(action?.title, "Notes")
    }

    // MARK: targetDirectory

    private let targeted = URL(fileURLWithPath: "/work/here", isDirectory: true)
    private let folderA = URL(fileURLWithPath: "/work/here/a", isDirectory: true)
    private let folderB = URL(fileURLWithPath: "/work/here/b", isDirectory: true)
    private let file = URL(fileURLWithPath: "/work/here/f.txt")
    private func isDirectory(_ url: URL) -> Bool { url != file }

    func testOneSelectedFolderIsTheTarget() {
        XCTAssertEqual(FinderMenu.targetDirectory(targeted: targeted, selected: [folderA], isDirectory: isDirectory), folderA)
    }

    func testOtherwiseTheTargetedFolderWins() {
        XCTAssertEqual(FinderMenu.targetDirectory(targeted: targeted, selected: [], isDirectory: isDirectory), targeted)
        XCTAssertEqual(FinderMenu.targetDirectory(targeted: targeted, selected: [file], isDirectory: isDirectory), targeted)
        XCTAssertEqual(FinderMenu.targetDirectory(targeted: targeted, selected: [folderA, folderB], isDirectory: isDirectory), targeted)
    }

    func testNoTargetAndNoSingleFolderIsNil() {
        XCTAssertNil(FinderMenu.targetDirectory(targeted: nil, selected: [], isDirectory: isDirectory))
        XCTAssertNil(FinderMenu.targetDirectory(targeted: nil, selected: [file], isDirectory: isDirectory))
        XCTAssertEqual(FinderMenu.targetDirectory(targeted: nil, selected: [folderB], isDirectory: isDirectory), folderB)
    }

    // MARK: menu kind, carried in the tag

    func testTheContainerMenuKeepsPlainIndexTags() {
        let config = FinderMenuConfig(actions: [off, markdown, text])
        XCTAssertEqual(FinderMenu.entries(for: config, kind: .container), FinderMenu.entries(for: config))
        XCTAssertEqual(FinderMenu.kind(forTag: 0), .container)
        XCTAssertEqual(FinderMenu.kind(forTag: 1), .container)
    }

    func testTheItemsMenuTagsCarryTheKindAndStillResolveTheAction() {
        let config = FinderMenuConfig(actions: [off, markdown, text])
        let offset = FinderMenu.itemsTagOffset
        XCTAssertEqual(FinderMenu.entries(for: config, kind: .items), [
            .item(title: "New Markdown File", tag: offset),
            .item(title: "New Text File", tag: offset + 1),
        ])
        XCTAssertEqual(FinderMenu.kind(forTag: offset), .items)
        XCTAssertEqual(FinderMenu.kind(forTag: offset + 1), .items)
        XCTAssertEqual(FinderMenu.action(forTag: offset, in: config)?.id, markdown.id)
        XCTAssertEqual(FinderMenu.action(forTag: offset + 1, in: config)?.id, text.id)
        XCTAssertNil(FinderMenu.action(forTag: offset + 2, in: config))
    }

    func testTheGroupedItemsMenuTagsCarryTheKindToo() {
        let config = FinderMenuConfig(actions: [markdown, text], groupInSubmenu: true)
        let offset = FinderMenu.itemsTagOffset
        XCTAssertEqual(FinderMenu.entries(for: config, kind: .items), [
            .submenu(title: "New File", items: [
                .item(title: "Markdown", tag: offset),
                .item(title: "Text", tag: offset + 1),
            ]),
        ])
    }

    func testTagsOutsideBothRangesHaveNoKindAndNoAction() {
        let config = FinderMenuConfig(actions: [markdown, text])
        let offset = FinderMenu.itemsTagOffset
        XCTAssertNil(FinderMenu.kind(forTag: -1))
        XCTAssertNil(FinderMenu.kind(forTag: 2 * offset))
        XCTAssertNil(FinderMenu.action(forTag: 2 * offset, in: config))
        XCTAssertNil(FinderMenu.action(forTag: -offset, in: config))
    }

    /// A blank-area right-click targets the window's folder even when a folder is still
    /// selected in it; only a right-click on the items applies the one-selected-folder rule.
    func testTheContainerMenuAlwaysTargetsTheTargetedFolder() {
        XCTAssertEqual(FinderMenu.targetDirectory(kind: .container, targeted: targeted, selected: [folderA], isDirectory: isDirectory), targeted)
        XCTAssertEqual(FinderMenu.targetDirectory(kind: .container, targeted: targeted, selected: [], isDirectory: isDirectory), targeted)
        XCTAssertNil(FinderMenu.targetDirectory(kind: .container, targeted: nil, selected: [folderA], isDirectory: isDirectory))
    }

    func testTheItemsMenuAppliesTheOneSelectedFolderRule() {
        XCTAssertEqual(FinderMenu.targetDirectory(kind: .items, targeted: targeted, selected: [folderA], isDirectory: isDirectory), folderA)
        XCTAssertEqual(FinderMenu.targetDirectory(kind: .items, targeted: targeted, selected: [file], isDirectory: isDirectory), targeted)
        XCTAssertEqual(FinderMenu.targetDirectory(kind: .items, targeted: targeted, selected: [folderA, folderB], isDirectory: isDirectory), targeted)
    }
}
