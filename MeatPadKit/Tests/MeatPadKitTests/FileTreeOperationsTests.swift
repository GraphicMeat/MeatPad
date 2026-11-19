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

    // MARK: createUntitledFile (Finder "New … File")

    func testUntitledFileIsUntitledDotExtAndEmpty() throws {
        let url = try FileTreeOperations.createUntitledFile(withExtension: "md", in: dir)
        XCTAssertEqual(url.lastPathComponent, "Untitled.md")
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path, dir.standardizedFileURL.path)
        XCTAssertEqual(try Data(contentsOf: url), Data())
    }

    func testUntitledFilesCountUpFromTwo() throws {
        let names = try (0..<3).map { _ in
            try FileTreeOperations.createUntitledFile(withExtension: "md", in: dir).lastPathComponent
        }
        XCTAssertEqual(names, ["Untitled.md", "Untitled 2.md", "Untitled 3.md"])
    }

    func testAnEmptyExtensionMeansNoDot() throws {
        let names = try (0..<2).map { _ in
            try FileTreeOperations.createUntitledFile(withExtension: "", in: dir).lastPathComponent
        }
        XCTAssertEqual(names, ["Untitled", "Untitled 2"])
    }

    func testExistingUntitledFilesKeepTheirBytes() throws {
        _ = try write("Untitled.md", "first")
        _ = try write("Untitled 2.md", "second")
        let url = try FileTreeOperations.createUntitledFile(withExtension: "md", in: dir)
        XCTAssertEqual(url.lastPathComponent, "Untitled 3.md")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("Untitled.md"), encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("Untitled 2.md"), encoding: .utf8), "second")
    }

    func testOnlyTheExactExtensionIsTaken() throws {
        _ = try write("Untitled.txt", "other")
        let url = try FileTreeOperations.createUntitledFile(withExtension: "md", in: dir)
        XCTAssertEqual(url.lastPathComponent, "Untitled.md")
    }

    func testADanglingSymlinkCountsAsTaken() throws {
        let link = dir.appendingPathComponent("Untitled.md")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: dir.appendingPathComponent("nowhere").path)
        let url = try FileTreeOperations.createUntitledFile(withExtension: "md", in: dir)
        XCTAssertEqual(url.lastPathComponent, "Untitled 2.md")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), dir.appendingPathComponent("nowhere").path)
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("nowhere").path), "the link's target was created through it")
    }

    func testAMissingDirectoryThrowsDirectoryMissingWithItsName() {
        let gone = dir.appendingPathComponent("Gone", isDirectory: true)
        XCTAssertThrowsError(try FileTreeOperations.createUntitledFile(withExtension: "md", in: gone)) {
            XCTAssertEqual($0 as? FileTreeError, .directoryMissing("Gone"))
        }
        XCTAssertFalse(fm.fileExists(atPath: gone.path))
    }

    func testARegularFileIsNotADirectory() throws {
        let file = try write("plain.txt", "keep")
        XCTAssertThrowsError(try FileTreeOperations.createUntitledFile(withExtension: "md", in: file)) {
            XCTAssertEqual($0 as? FileTreeError, .directoryMissing("plain.txt"))
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "keep")
    }

    func testACustomBaseName() throws {
        let url = try FileTreeOperations.createUntitledFile(withExtension: "txt", in: dir, baseName: "Notes")
        XCTAssertEqual(url.lastPathComponent, "Notes.txt")
    }
}
