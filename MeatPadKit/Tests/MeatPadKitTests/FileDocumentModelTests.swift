import XCTest
@testable import MeatPadKit

@MainActor
final class FileDocumentModelTests: XCTestCase {

    private var fileURL: URL!

    override func setUpWithError() throws {
        fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL)
        fileURL = nil
    }

    private func write(_ string: String) throws {
        try Data(string.utf8).write(to: fileURL, options: .atomic)
    }

    // MARK: - init / load

    func testInitLoadsContentsFromDisk() throws {
        try write("Hello World")
        let model = try FileDocumentModel(url: fileURL)
        XCTAssertEqual(model.contents, "Hello World")
        XCTAssertEqual(model.editedContents, "Hello World")
        XCTAssertFalse(model.isDirty)
    }

    // MARK: - editedContents / isDirty

    func testEditingContentsSetsDirty() throws {
        try write("Hello")
        let model = try FileDocumentModel(url: fileURL)
        model.editedContents = "Hello!"
        XCTAssertTrue(model.isDirty)
    }

    func testEditingBackToOriginalClearsDirty() throws {
        try write("Hello")
        let model = try FileDocumentModel(url: fileURL)
        model.editedContents = "Hello!"
        XCTAssertTrue(model.isDirty)
        model.editedContents = "Hello"
        XCTAssertFalse(model.isDirty)
    }

    // MARK: - save

    func testSaveWritesAtomicallyAndClearsDirty() throws {
        try write("Hello")
        let model = try FileDocumentModel(url: fileURL)
        model.editedContents = "Hello, World!"
        try model.save()

        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.contents, "Hello, World!")
        let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertEqual(onDisk, "Hello, World!")
    }

    // MARK: - revert

    func testRevertRestoresDiskContentsAndClearsDirty() throws {
        try write("Original")
        let model = try FileDocumentModel(url: fileURL)
        model.editedContents = "Changed but not saved"
        XCTAssertTrue(model.isDirty)

        try model.revert()

        XCTAssertEqual(model.contents, "Original")
        XCTAssertEqual(model.editedContents, "Original")
        XCTAssertFalse(model.isDirty)
    }

    // MARK: - checkExternalChange

    func testCheckExternalChangeDetectsNewerMtimeOnDisk() throws {
        try write("Original")
        let model = try FileDocumentModel(url: fileURL)

        // Ensure the new mtime is strictly newer than the loaded snapshot.
        Thread.sleep(forTimeInterval: 1.1)
        try write("Modified externally")

        XCTAssertEqual(model.checkExternalChange(), .changedOnDisk)
    }

    func testCheckExternalChangeReturnsDeletedWhenFileMissing() throws {
        try write("Original")
        let model = try FileDocumentModel(url: fileURL)

        try FileManager.default.removeItem(at: fileURL)

        XCTAssertEqual(model.checkExternalChange(), .deleted)
    }

    func testCheckExternalChangeReturnsNoneAfterSaveRefreshesSnapshot() throws {
        try write("Original")
        let model = try FileDocumentModel(url: fileURL)

        Thread.sleep(forTimeInterval: 1.1)
        model.editedContents = "Saved content"
        try model.save()

        XCTAssertEqual(model.checkExternalChange(), .none)
    }
}
