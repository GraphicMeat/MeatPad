import XCTest
@testable import MeatPadKit

@MainActor
final class ProjectTreeTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    private func makeFile(_ relativePath: String, in dir: URL? = nil) throws {
        let url = (dir ?? tempDir).appendingPathComponent(relativePath)
        try Data("x".utf8).write(to: url)
    }

    private func makeDir(_ relativePath: String, in dir: URL? = nil) throws -> URL {
        let url = (dir ?? tempDir).appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - scan ordering

    func testScanOrdersDirsFirstThenFilesBothAlphabeticalCaseInsensitive() throws {
        try makeFile("banana.txt")
        try makeFile("Apple.txt")
        _ = try makeDir("zebra")
        _ = try makeDir("Aardvark")

        let node = ProjectScanner.scan(root: tempDir)

        XCTAssertEqual(node.children?.map(\.name), ["Aardvark", "zebra", "Apple.txt", "banana.txt"])
        XCTAssertEqual(node.children?.map(\.isDirectory), [true, true, false, false])
    }

    // MARK: - ignoredNames

    func testIgnoredNamesAreExcluded() throws {
        _ = try makeDir(".git")
        _ = try makeDir("node_modules")
        _ = try makeDir(".build")
        _ = try makeDir("DerivedData")
        try makeFile(".DS_Store")
        try makeFile("keep.txt")

        let node = ProjectScanner.scan(root: tempDir, showHidden: true)

        XCTAssertEqual(node.children?.map(\.name), ["keep.txt"])
    }

    func testIgnoredNamesConstant() {
        XCTAssertEqual(ProjectScanner.ignoredNames, [".git", "node_modules", ".build", "DerivedData", ".DS_Store"])
    }

    // MARK: - hidden files

    func testHiddenEntriesExcludedByDefault() throws {
        try makeFile(".hidden.txt")
        try makeFile("visible.txt")
        _ = try makeDir(".hiddenDir")

        let node = ProjectScanner.scan(root: tempDir)

        XCTAssertEqual(node.children?.map(\.name), ["visible.txt"])
    }

    func testHiddenEntriesIncludedWhenShowHiddenTrue() throws {
        try makeFile(".hidden.txt")
        try makeFile("visible.txt")

        let node = ProjectScanner.scan(root: tempDir, showHidden: true)

        XCTAssertEqual(node.children?.map(\.name), [".hidden.txt", "visible.txt"])
    }

    // MARK: - recursion

    func testScanRecursesIntoSubdirectories() throws {
        let sub = try makeDir("sub")
        try makeFile("inner.txt", in: sub)
        try makeFile("outer.txt")

        let node = ProjectScanner.scan(root: tempDir)

        let subNode = node.children?.first(where: { $0.name == "sub" })
        XCTAssertNotNil(subNode)
        XCTAssertEqual(subNode?.children?.map(\.name), ["inner.txt"])
    }

    func testFilesHaveNilChildrenDirsHaveNonNilChildren() throws {
        _ = try makeDir("emptyDir")
        try makeFile("file.txt")

        let node = ProjectScanner.scan(root: tempDir)

        let dirNode = node.children?.first(where: { $0.name == "emptyDir" })
        let fileNode = node.children?.first(where: { $0.name == "file.txt" })
        XCTAssertNotNil(dirNode?.children)
        XCTAssertNil(fileNode?.children)
    }

    // MARK: - symlinks

    func testSymlinkIsTreatedAsFileNotFollowed() throws {
        let realDir = try makeDir("realDir")
        try makeFile("real.txt", in: realDir)
        let linkURL = tempDir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: realDir)

        let node = ProjectScanner.scan(root: tempDir)

        let linkNode = node.children?.first(where: { $0.name == "link" })
        XCTAssertNotNil(linkNode)
        XCTAssertFalse(linkNode?.isDirectory ?? true)
        XCTAssertNil(linkNode?.children)
    }

    // MARK: - flatFileList

    func testFlatFileListReturnsOnlyFilesRecursivelyInTreeOrder() throws {
        let sub = try makeDir("sub")
        try makeFile("b.txt", in: sub)
        try makeFile("a.txt")
        _ = try makeDir("emptyDir")

        let node = ProjectScanner.scan(root: tempDir)
        let files = ProjectScanner.flatFileList(node)

        XCTAssertEqual(files.map(\.lastPathComponent), ["b.txt", "a.txt"])
    }

    func testFlatFileListEmptyForNoFiles() throws {
        _ = try makeDir("onlyDir")

        let node = ProjectScanner.scan(root: tempDir)
        let files = ProjectScanner.flatFileList(node)

        XCTAssertEqual(files, [])
    }

    // MARK: - scanShallow

    func testScanShallowListsTopLevelWithoutRecursingAndMatchesScanOrdering() throws {
        let sub = try makeDir("sub")
        try makeFile("inner.txt", in: sub)
        try makeFile("outer.txt")

        let shallow = ProjectScanner.scanShallow(root: tempDir)
        let full = ProjectScanner.scan(root: tempDir)

        XCTAssertEqual(shallow.children?.map(\.name), ["sub", "outer.txt"])
        XCTAssertEqual(shallow.children?.first(where: { $0.name == "sub" })?.children, [])
        XCTAssertEqual(full.children?.map(\.name), shallow.children?.map(\.name))
        XCTAssertEqual(full.children?.first(where: { $0.name == "sub" })?.children?.map(\.name), ["inner.txt"])
    }

    // MARK: - lazy expansion

    func testScanOnlyDescendsIntoExpandedFolders() throws {
        let open = try makeDir("open")
        let closed = try makeDir("closed")
        let deep = try makeDir("deep", in: open)
        try makeFile("a.txt", in: open)
        try makeFile("b.txt", in: closed)
        try makeFile("c.txt", in: deep)

        let node = ProjectScanner.scan(root: tempDir, expanded: [open])

        let openNode = node.children?.first(where: { $0.name == "open" })
        XCTAssertEqual(openNode?.children?.map(\.name), ["deep", "a.txt"])
        XCTAssertEqual(openNode?.children?.first(where: { $0.name == "deep" })?.children, [])
        XCTAssertEqual(node.children?.first(where: { $0.name == "closed" })?.children, [])
    }

    func testScanKeepsExpandedDescendantsOfExpandedFolders() throws {
        let open = try makeDir("open")
        let deep = try makeDir("deep", in: open)
        try makeFile("c.txt", in: deep)

        let node = ProjectScanner.scan(root: tempDir, expanded: [open, deep])

        let deepNode = node.children?.first?.children?.first
        XCTAssertEqual(deepNode?.children?.map(\.name), ["c.txt"])
    }

    func testSettingChildrenSplicesAFoldedFolderInPlace() throws {
        let sub = try makeDir("sub")
        let deep = try makeDir("deep", in: sub)
        try makeFile("c.txt", in: deep)
        try makeFile("other.txt")

        let shallow = ProjectScanner.scanShallow(root: tempDir)
        let loadedSub = ProjectScanner.scan(root: sub, expanded: [])
        let spliced = shallow.settingChildren(loadedSub.children, at: sub)
        XCTAssertEqual(spliced.children?.first?.children?.map(\.name), ["deep"])

        let loadedDeep = ProjectScanner.scan(root: deep, expanded: [])
        let deeper = spliced.settingChildren(loadedDeep.children, at: deep)
        XCTAssertEqual(deeper.children?.first?.children?.first?.children?.map(\.name), ["c.txt"])

        let folded = deeper.settingChildren([], at: sub)
        XCTAssertEqual(folded.children?.first?.children, [])
        XCTAssertEqual(folded.children?.map(\.name), ["sub", "other.txt"])
    }

    func testSettingChildrenOnMissingTargetChangesNothing() throws {
        _ = try makeDir("sub")
        let shallow = ProjectScanner.scanShallow(root: tempDir)
        let ghost = tempDir.appendingPathComponent("sub/ghost")

        XCTAssertEqual(shallow.settingChildren([], at: ghost), shallow)
    }

    // MARK: - forEachFile

    func testForEachFileWalksEveryFileSkippingIgnoredAndHidden() throws {
        let sub = try makeDir("sub")
        let pods = try makeDir("Pods")
        let git = try makeDir(".git")
        try makeFile("a.txt")
        try makeFile("b.txt", in: sub)
        try makeFile("vendored.txt", in: pods)
        try makeFile("HEAD", in: git)
        try makeFile(".hidden")

        var names: [String] = []
        ProjectScanner.forEachFile(root: tempDir) { names.append($0.lastPathComponent); return true }

        XCTAssertEqual(Set(names), ["a.txt", "b.txt"])
    }

    func testForEachFileStopsWhenBodyReturnsFalse() throws {
        for i in 0..<5 { try makeFile("f\(i).txt") }

        var count = 0
        ProjectScanner.forEachFile(root: tempDir) { _ in count += 1; return count < 2 }

        XCTAssertEqual(count, 2)
    }

    func testWalkIgnoredNamesExtendIgnoredNames() {
        XCTAssertTrue(ProjectScanner.ignoredNames.isSubset(of: ProjectScanner.walkIgnoredNames))
    }

    // MARK: - TreeNode identity

    func testTreeNodeIDIsURL() throws {
        try makeFile("a.txt")
        let node = ProjectScanner.scan(root: tempDir)
        let child = node.children?.first
        XCTAssertEqual(child?.id, child?.url)
    }
}
