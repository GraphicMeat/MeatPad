import XCTest
@testable import MeatPadKit

@MainActor
final class NoteStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    private func makeStore() throws -> NoteStore {
        try NoteStore(rootURL: tempDir)
    }

    // MARK: - init

    func testInitCreatesRootAndTrashDirectories() throws {
        _ = try makeStore()
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        let trash = tempDir.appendingPathComponent(".trash")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    // MARK: - createNote

    func testCreateNoteWritesFilesAndAppearsInNotes() throws {
        let store = try makeStore()
        let note = try store.createNote()

        let txtURL = tempDir.appendingPathComponent("\(note.id.uuidString).txt")
        let jsonURL = tempDir.appendingPathComponent("\(note.id.uuidString).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: txtURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonURL.path))
        XCTAssertTrue(store.notes.contains(where: { $0.id == note.id }))
    }

    func testCreateNoteTitleIsNewNote() throws {
        let store = try makeStore()
        let note = try store.createNote()
        XCTAssertEqual(note.title, "New Note")
    }

    // MARK: - save

    func testSaveUpdatesContentsAndTitleFromFirstLine() throws {
        let store = try makeStore()
        let note = try store.createNote()

        try store.save(id: note.id, contents: "Hello World\nsecond line", cursor: 5)

        XCTAssertEqual(try store.contents(of: note.id), "Hello World\nsecond line")
        let updated = store.notes.first(where: { $0.id == note.id })
        XCTAssertEqual(updated?.title, "Hello World")
        XCTAssertEqual(updated?.cursor, 5)
    }

    func testSaveWithNoNonEmptyLineTitleIsNewNote() throws {
        let store = try makeStore()
        let note = try store.createNote()

        try store.save(id: note.id, contents: "   \n\n  ", cursor: 0)

        let updated = store.notes.first(where: { $0.id == note.id })
        XCTAssertEqual(updated?.title, "New Note")
    }

    // MARK: - setLanguage

    func testSetLanguageUpdatesLanguageID() throws {
        let store = try makeStore()
        let note = try store.createNote()

        try store.setLanguage(id: note.id, languageID: "swift")

        XCTAssertEqual(store.notes.first(where: { $0.id == note.id })?.languageID, "swift")
    }

    // MARK: - persistence (reload)

    func testReloadViaNewStoreInstanceSeesSameNotes() throws {
        let store1 = try makeStore()
        let note = try store1.createNote()
        try store1.save(id: note.id, contents: "Persisted note", cursor: 3)

        let store2 = try makeStore()

        XCTAssertEqual(store2.notes.count, 1)
        XCTAssertEqual(store2.notes.first?.id, note.id)
        XCTAssertEqual(store2.notes.first?.title, "Persisted note")
        XCTAssertEqual(store2.notes.first?.cursor, 3)
        XCTAssertEqual(try store2.contents(of: note.id), "Persisted note")
    }

    // MARK: - trash

    func testTrashRemovesFromListAndMovesFilesToTrashDir() throws {
        let store = try makeStore()
        let note = try store.createNote()

        try store.trash(id: note.id)

        XCTAssertFalse(store.notes.contains(where: { $0.id == note.id }))
        let trashedTxt = tempDir.appendingPathComponent(".trash/\(note.id.uuidString).txt")
        let trashedJSON = tempDir.appendingPathComponent(".trash/\(note.id.uuidString).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashedTxt.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashedJSON.path))

        let originalTxt = tempDir.appendingPathComponent("\(note.id.uuidString).txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalTxt.path))
    }

    // MARK: - sorting

    func testNotesAreSortedByModifiedDescending() throws {
        let store = try makeStore()
        let first = try store.createNote()
        try store.save(id: first.id, contents: "first", cursor: 0)

        let second = try store.createNote()
        try store.save(id: second.id, contents: "second", cursor: 0)

        // Force a distinguishable modified order regardless of clock resolution.
        try store.save(id: first.id, contents: "first again", cursor: 0)

        XCTAssertEqual(store.notes.first?.id, first.id)
    }

    // MARK: - self-healing load

    func testCorruptSidecarIsRegeneratedFromTxt() throws {
        let store1 = try makeStore()
        let note = try store1.createNote()
        try store1.save(id: note.id, contents: "Survivor title\nbody", cursor: 2)

        let jsonURL = tempDir.appendingPathComponent("\(note.id.uuidString).json")
        try Data("not json {{{".utf8).write(to: jsonURL)

        let store2 = try makeStore()
        let recovered = store2.notes.first(where: { $0.id == note.id })
        XCTAssertNotNil(recovered)
        XCTAssertEqual(recovered?.title, "Survivor title")
        XCTAssertEqual(try store2.contents(of: note.id), "Survivor title\nbody")
        // repaired sidecar was written back to disk
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)))
    }

    func testOrphanTxtWithNoSidecarBecomesVisible() throws {
        _ = try makeStore() // creates dirs
        let id = UUID()
        try Data("Orphan note".utf8).write(to: tempDir.appendingPathComponent("\(id.uuidString).txt"))

        let store = try makeStore()
        let recovered = store.notes.first(where: { $0.id == id })
        XCTAssertNotNil(recovered)
        XCTAssertEqual(recovered?.title, "Orphan note")
        XCTAssertEqual(try store.contents(of: id), "Orphan note")
    }

    func testCorruptSidecarDoesNotAffectOtherNotes() throws {
        let store1 = try makeStore()
        let bad = try store1.createNote()
        let good = try store1.createNote()
        try store1.save(id: good.id, contents: "Good note", cursor: 0)
        try Data([0xFF, 0x00, 0x42]).write(to: tempDir.appendingPathComponent("\(bad.id.uuidString).json"))

        let store2 = try makeStore()
        XCTAssertEqual(store2.notes.count, 2)
        XCTAssertEqual(store2.notes.first(where: { $0.id == good.id })?.title, "Good note")
        XCTAssertEqual(store2.notes.first(where: { $0.id == good.id })?.cursor, 0)
    }

    func testSidecarWithMissingTxtGetsEmptyTxt() throws {
        let store1 = try makeStore()
        let note = try store1.createNote()
        try FileManager.default.removeItem(at: tempDir.appendingPathComponent("\(note.id.uuidString).txt"))

        let store2 = try makeStore()
        XCTAssertTrue(store2.notes.contains(where: { $0.id == note.id }))
        XCTAssertEqual(try store2.contents(of: note.id), "")
    }

    // MARK: - unknown id

    func testUnknownIDThrowsNotFound() throws {
        let store = try makeStore()
        let bogus = UUID()
        XCTAssertThrowsError(try store.contents(of: bogus)) { XCTAssertEqual($0 as? NoteStoreError, .notFound(bogus)) }
        XCTAssertThrowsError(try store.save(id: bogus, contents: "", cursor: 0)) { XCTAssertEqual($0 as? NoteStoreError, .notFound(bogus)) }
        XCTAssertThrowsError(try store.setLanguage(id: bogus, languageID: nil)) { XCTAssertEqual($0 as? NoteStoreError, .notFound(bogus)) }
        XCTAssertThrowsError(try store.trash(id: bogus)) { XCTAssertEqual($0 as? NoteStoreError, .notFound(bogus)) }
    }

    // MARK: - defaultRoot

    func testDefaultRootPointsAtApplicationSupportMeatPadNotes() {
        let root = NoteStore.defaultRoot()
        XCTAssertTrue(root.path.hasSuffix("Application Support/MeatPad/Notes"))
    }
}
