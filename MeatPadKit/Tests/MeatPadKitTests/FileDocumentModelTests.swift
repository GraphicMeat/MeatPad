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

    private func setMtime(_ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: fileURL.path)
    }

    // MARK: - init / load

    func testInitLoadsContentsFromDisk() throws {
        try write("Hello World")
        let model = try FileDocumentModel(url: fileURL)
        XCTAssertEqual(model.contents, "Hello World")
        XCTAssertEqual(model.editedContents, "Hello World")
        XCTAssertFalse(model.isDirty)
    }

    func testInitDecodesInvalidUTF8Lossily() throws {
        // "Hi" + invalid bytes + "!" — must open (never refuse a text file), lossily.
        try Data([0x48, 0x69, 0xFF, 0xC0, 0x21]).write(to: fileURL, options: .atomic)
        let model = try FileDocumentModel(url: fileURL)
        XCTAssertTrue(model.contents.hasPrefix("Hi"))
        XCTAssertTrue(model.contents.contains("\u{FFFD}"))
        XCTAssertTrue(model.contents.hasSuffix("!"))
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

        try write("Modified externally")
        // Force a strictly newer mtime deterministically (no sleep, no fs-granularity flake).
        try setMtime(Date().addingTimeInterval(10))

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

        // Make the on-disk mtime strictly newer than the init snapshot, so a stale
        // snapshot would report .changedOnDisk...
        try setMtime(Date().addingTimeInterval(10))
        XCTAssertEqual(model.checkExternalChange(), .changedOnDisk)

        model.editedContents = "Saved content"
        try model.save()

        // ...and save() must have refreshed the snapshot to the post-write mtime.
        XCTAssertEqual(model.checkExternalChange(), .none)
    }
}
