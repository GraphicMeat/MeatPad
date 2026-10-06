import XCTest
@testable import MeatPadKit

final class FileTreePathsTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/work/proj", isDirectory: true)

    func testRelativePathInsideTheRoot() {
        XCTAssertEqual(FileTreePaths.relativePath(of: URL(fileURLWithPath: "/work/proj/a.txt"), in: root), "a.txt")
        XCTAssertEqual(FileTreePaths.relativePath(of: URL(fileURLWithPath: "/work/proj/src/deep/b.swift"), in: root), "src/deep/b.swift")
    }

    func testRelativePathOfTheRootItselfIsDot() {
        XCTAssertEqual(FileTreePaths.relativePath(of: root, in: root), ".")
    }

    func testRelativePathOutsideTheRootFallsBackToTheAbsolutePath() {
        XCTAssertEqual(FileTreePaths.relativePath(of: URL(fileURLWithPath: "/elsewhere/c.txt"), in: root), "/elsewhere/c.txt")
    }

    func testRelativePathDoesNotMistakeASiblingWithTheSamePrefix() {
        XCTAssertEqual(FileTreePaths.relativePath(of: URL(fileURLWithPath: "/work/proj-two/d.txt"), in: root), "/work/proj-two/d.txt")
    }

    func testContainingDirectoryIsTheFolderItselfOrTheFilesParent() {
        let folder = URL(fileURLWithPath: "/work/proj/src", isDirectory: true)
        let file = URL(fileURLWithPath: "/work/proj/src/a.txt")
        XCTAssertEqual(FileTreePaths.containingDirectory(of: folder, isDirectory: true), folder)
        XCTAssertEqual(FileTreePaths.containingDirectory(of: file, isDirectory: false).path, "/work/proj/src")
    }
}

final class FileTreeOperationsTests: XCTestCase {

    private var dir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        dir = fm.temporaryDirectory.appendingPathComponent("FileTreeOps-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: dir)
    }

    private func write(_ name: String, _ text: String = "x", in folder: URL? = nil) throws -> URL {
        let url = (folder ?? dir).appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func folder(_ name: String, in parent: URL? = nil) throws -> URL {
        let url = (parent ?? dir).appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: create

    func testCreateFileMakesAnEmptyFile() throws {
        let url = try FileTreeOperations.createFile(named: "new.txt", in: dir)
        XCTAssertEqual(url.lastPathComponent, "new.txt")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "")
    }

    func testCreateFolderMakesADirectory() throws {
        let url = try FileTreeOperations.createFolder(named: "sub", in: dir)
        var isDir: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: url.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testCreateRefusesAnExistingName() throws {
        _ = try write("a.txt", "keep")
        XCTAssertThrowsError(try FileTreeOperations.createFile(named: "a.txt", in: dir)) {
            XCTAssertEqual($0 as? FileTreeError, .alreadyExists("a.txt"))
        }
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("a.txt"), encoding: .utf8), "keep")
    }

    func testInvalidNamesAreRejected() {
        for name in ["", "   ", ".", "..", "a/b"] {
            XCTAssertThrowsError(try FileTreeOperations.createFile(named: name, in: dir), name) {
                XCTAssertEqual($0 as? FileTreeError, .invalidName, name)
            }
        }
    }

    func testNamesAreTrimmed() throws {
        let url = try FileTreeOperations.createFile(named: "  padded.txt \n", in: dir)
        XCTAssertEqual(url.lastPathComponent, "padded.txt")
    }

    // MARK: rename

    func testRenameMovesTheItem() throws {
        let old = try write("old.txt", "hello")
        let new = try FileTreeOperations.rename(old, to: "new.txt")
        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertEqual(try String(contentsOf: new, encoding: .utf8), "hello")
    }

    func testRenameToTheSameNameIsANoOp() throws {
        let url = try write("same.txt")
        XCTAssertEqual(try FileTreeOperations.rename(url, to: "same.txt"), url)
        XCTAssertTrue(fm.fileExists(atPath: url.path))
    }

    func testRenameOntoAnExistingNameThrowsAndKeepsBoth() throws {
        let a = try write("a.txt", "A")
        let b = try write("b.txt", "B")
        XCTAssertThrowsError(try FileTreeOperations.rename(a, to: "b.txt")) {
            XCTAssertEqual($0 as? FileTreeError, .alreadyExists("b.txt"))
        }
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "A")
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "B")
    }

    // MARK: trash

    func testTrashRemovesTheItemFromItsFolder() throws {
        let url = try write("gone.txt")
        try FileTreeOperations.trash(url)
        XCTAssertFalse(fm.fileExists(atPath: url.path))
    }

    // MARK: paste

    func testCopyPasteIntoAnotherFolderKeepsTheOriginal() throws {
        let file = try write("a.txt", "A")
        let target = try folder("sub")
        let made = try FileTreeOperations.paste([file], into: target, move: false)
        XCTAssertEqual(made.map(\.lastPathComponent), ["a.txt"])
        XCTAssertTrue(fm.fileExists(atPath: file.path))
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("a.txt"), encoding: .utf8), "A")
    }

    func testPasteIntoTheSameFolderPicksACopyName() throws {
        let file = try write("a.txt")
        let first = try FileTreeOperations.paste([file], into: dir, move: false)
        let second = try FileTreeOperations.paste([file], into: dir, move: false)
        XCTAssertEqual(first.first?.lastPathComponent, "a copy.txt")
        XCTAssertEqual(second.first?.lastPathComponent, "a copy 2.txt")
    }

    func testCopyNameForAFolderHasNoExtensionSplit() throws {
        let src = try folder("assets.v2")
        let made = try FileTreeOperations.paste([src], into: dir, move: false)
        XCTAssertEqual(made.first?.lastPathComponent, "assets.v2 copy")
    }

    func testCopyingAFolderCopiesItsContents() throws {
        let src = try folder("src")
        _ = try write("in.txt", "deep", in: src)
        let target = try folder("dest")
        let made = try FileTreeOperations.paste([src], into: target, move: false)
        XCTAssertEqual(try String(contentsOf: made[0].appendingPathComponent("in.txt"), encoding: .utf8), "deep")
    }

    func testMovePasteRemovesTheOriginal() throws {
        let file = try write("a.txt", "A")
        let target = try folder("sub")
        let made = try FileTreeOperations.paste([file], into: target, move: true)
        XCTAssertFalse(fm.fileExists(atPath: file.path))
        XCTAssertEqual(try String(contentsOf: made[0], encoding: .utf8), "A")
    }

    func testMovingIntoTheSameFolderLeavesItAlone() throws {
        let file = try write("a.txt")
        let made = try FileTreeOperations.paste([file], into: dir, move: true)
        XCTAssertEqual(made, [file])
        XCTAssertTrue(fm.fileExists(atPath: file.path))
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("a copy.txt").path))
    }

    func testMovingAFolderIntoItselfOrADescendantThrows() throws {
        let outer = try folder("outer")
        let inner = try folder("inner", in: outer)
        XCTAssertThrowsError(try FileTreeOperations.paste([outer], into: outer, move: true)) {
            XCTAssertEqual($0 as? FileTreeError, .cannotMoveIntoItself)
        }
        XCTAssertThrowsError(try FileTreeOperations.paste([outer], into: inner, move: true)) {
            XCTAssertEqual($0 as? FileTreeError, .cannotMoveIntoItself)
        }
        XCTAssertTrue(fm.fileExists(atPath: inner.path))
    }

    func testCopyingAFolderIntoItselfThrowsToo() throws {
        let outer = try folder("outer")
        XCTAssertThrowsError(try FileTreeOperations.paste([outer], into: outer, move: false)) {
            XCTAssertEqual($0 as? FileTreeError, .cannotMoveIntoItself)
        }
    }
}
