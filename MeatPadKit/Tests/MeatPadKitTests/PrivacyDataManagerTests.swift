import XCTest
@testable import MeatPadKit

final class PrivacyDataManagerTests: XCTestCase {

    private var tempDir: URL!
    private var sourceBase: URL!
    private var destBase: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        sourceBase = tempDir.appendingPathComponent("source", isDirectory: true)
        destBase = tempDir.appendingPathComponent("dest", isDirectory: true)
        try fm.createDirectory(at: sourceBase, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tempDir)
        tempDir = nil
    }

    private func write(_ text: String, to relativePath: String, under base: URL) throws {
        let url = base.appendingPathComponent(relativePath)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - fileCount

    func testFileCountMissingPathIsZero() {
        XCTAssertEqual(PrivacyDataManager.fileCount(at: sourceBase.appendingPathComponent("nope")), 0)
    }

    func testFileCountSingleFileIsOne() throws {
        try write("hi", to: "session.json", under: sourceBase)
        XCTAssertEqual(PrivacyDataManager.fileCount(at: sourceBase.appendingPathComponent("session.json")), 1)
    }

    func testFileCountRecursesNestedDirectories() throws {
        try write("a", to: "Notes/a.txt", under: sourceBase)
        try write("b", to: "Notes/sub/b.txt", under: sourceBase)
        XCTAssertEqual(PrivacyDataManager.fileCount(at: sourceBase.appendingPathComponent("Notes")), 2)
    }

    // MARK: - existingArtifacts

    func testExistingArtifactsSkipsMissingOnes() throws {
        try write("a", to: "Notes/a.txt", under: sourceBase)
        try write("{}", to: "session.json", under: sourceBase)
        let found = PrivacyDataManager.existingArtifacts(at: sourceBase)
        XCTAssertEqual(found.map(\.lastPathComponent), ["Notes", "session.json"])
    }

    // MARK: - copyManagedArtifacts

    func testCopyManagedArtifactsCopiesAllExistingSiblings() throws {
        try write("note", to: "Notes/a.txt", under: sourceBase)
        try write("snip", to: "Snippets/s.json", under: sourceBase)
        try write("cmd", to: "Commands/c.json", under: sourceBase)
        try write("session", to: "session.json", under: sourceBase)
        // Macros/Themes deliberately absent — a fresh install may not have them yet.

        let counts = try PrivacyDataManager.copyManagedArtifacts(from: sourceBase, to: destBase)

        XCTAssertEqual(counts, ["Notes": 1, "Snippets": 1, "Commands": 1, "session.json": 1])
        XCTAssertEqual(try String(contentsOf: destBase.appendingPathComponent("Notes/a.txt"), encoding: .utf8), "note")
        XCTAssertFalse(fm.fileExists(atPath: destBase.appendingPathComponent("Macros").path))
    }

    func testCopyManagedArtifactsCreatesDestinationDirectory() throws {
        try write("note", to: "Notes/a.txt", under: sourceBase)
        XCTAssertFalse(fm.fileExists(atPath: destBase.path))
        _ = try PrivacyDataManager.copyManagedArtifacts(from: sourceBase, to: destBase)
        XCTAssertTrue(fm.fileExists(atPath: destBase.path))
    }

    func testCopyManagedArtifactsThrowsOnVerificationMismatch() throws {
        try write("note", to: "Notes/a.txt", under: sourceBase)

        // A FileManager whose copyItem "succeeds" but silently drops files simulates a
        // corrupted copy — verification must catch it rather than trust copyItem blindly.
        final class LossyFileManager: FileManager {
            override func copyItem(at srcURL: URL, to dstURL: URL) throws {
                try FileManager.default.createDirectory(at: dstURL, withIntermediateDirectories: true)
                // Deliberately don't copy the file inside.
            }
        }

        XCTAssertThrowsError(
            try PrivacyDataManager.copyManagedArtifacts(from: sourceBase, to: destBase, fileManager: LossyFileManager())
        ) { error in
            guard case PrivacyDataError.verificationFailed(let artifact, let sourceCount, let destinationCount) = error else {
                return XCTFail("Expected verificationFailed, got \(error)")
            }
            XCTAssertEqual(artifact, "Notes")
            XCTAssertEqual(sourceCount, 1)
            XCTAssertEqual(destinationCount, 0)
        }
    }

    // MARK: - destinationInsideSource guard (data-loss regression)

    func testCopyManagedArtifactsThrowsWhenDestinationEqualsSourceWithoutMutatingSource() throws {
        try write("note", to: "Notes/a.txt", under: sourceBase)

        XCTAssertThrowsError(
            try PrivacyDataManager.copyManagedArtifacts(from: sourceBase, to: sourceBase)
        ) { error in
            guard case PrivacyDataError.destinationInsideSource = error else {
                return XCTFail("Expected destinationInsideSource, got \(error)")
            }
        }

        // The whole point of the guard: source must be untouched, not partially deleted.
        XCTAssertEqual(try String(contentsOf: sourceBase.appendingPathComponent("Notes/a.txt"), encoding: .utf8), "note")
    }

    func testCopyManagedArtifactsThrowsWhenDestinationIsChildOfSource() throws {
        try write("note", to: "Notes/a.txt", under: sourceBase)
        let nestedDestination = sourceBase.appendingPathComponent("Backup", isDirectory: true)

        XCTAssertThrowsError(
            try PrivacyDataManager.copyManagedArtifacts(from: sourceBase, to: nestedDestination)
        ) { error in
            guard case PrivacyDataError.destinationInsideSource = error else {
                return XCTFail("Expected destinationInsideSource, got \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: sourceBase.appendingPathComponent("Notes/a.txt"), encoding: .utf8), "note")
    }

    func testCopyManagedArtifactsAllowsSiblingWithCommonPrefix() throws {
        try write("note", to: "Notes/a.txt", under: sourceBase)
        // sourceBase is ".../source"; this sibling shares "source" as a path prefix but is
        // NOT a descendant of it — must not be rejected by the guard.
        let siblingDestination = tempDir.appendingPathComponent("sourceBackup", isDirectory: true)

        let counts = try PrivacyDataManager.copyManagedArtifacts(from: sourceBase, to: siblingDestination)

        XCTAssertEqual(counts, ["Notes": 1])
    }

    func testCopyManagedArtifactsOverwritesExistingDestination() throws {
        try write("v1", to: "Notes/a.txt", under: sourceBase)
        _ = try PrivacyDataManager.copyManagedArtifacts(from: sourceBase, to: destBase)
        try write("v2", to: "Notes/a.txt", under: sourceBase)
        try write("v2", to: "Notes/b.txt", under: sourceBase)

        _ = try PrivacyDataManager.copyManagedArtifacts(from: sourceBase, to: destBase)

        XCTAssertEqual(try String(contentsOf: destBase.appendingPathComponent("Notes/a.txt"), encoding: .utf8), "v2")
        XCTAssertTrue(fm.fileExists(atPath: destBase.appendingPathComponent("Notes/b.txt").path))
    }

    // MARK: - managed artifacts

    func testManagedArtifactsIncludeBoards() {
        XCTAssertTrue(PrivacyDataManager.managedArtifactNames.contains("Boards"))
    }
}
