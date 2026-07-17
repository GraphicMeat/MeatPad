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

    // MARK: - TreeNode identity

    func testTreeNodeIDIsURL() throws {
        try makeFile("a.txt")
        let node = ProjectScanner.scan(root: tempDir)
        let child = node.children?.first
        XCTAssertEqual(child?.id, child?.url)
    }
}
