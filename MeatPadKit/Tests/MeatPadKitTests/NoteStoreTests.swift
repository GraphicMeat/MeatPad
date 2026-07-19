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

    func testSaveWithCRLFContentTitleTrimsCarriageReturn() throws {
        let store = try makeStore()
        let note = try store.createNote()

        try store.save(id: note.id, contents: "Hello\r\nWorld", cursor: 0)

        let updated = store.notes.first(where: { $0.id == note.id })
        XCTAssertEqual(updated?.title, "Hello")
    }

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

    // MARK: - window frame

    func testWindowFrameRoundTripsThroughSidecar() throws {
        let store1 = try makeStore()
        let note = try store1.createNote()

        try store1.setWindowFrame(id: note.id, frame: "{{100, 200}, {800, 600}}")

        XCTAssertEqual(store1.notes.first(where: { $0.id == note.id })?.windowFrame, "{{100, 200}, {800, 600}}")
        let store2 = try makeStore()
        XCTAssertEqual(store2.notes.first(where: { $0.id == note.id })?.windowFrame, "{{100, 200}, {800, 600}}")
    }

    func testLegacySidecarWithoutWindowFrameDecodes() throws {
        _ = try makeStore() // creates dirs
        let id = UUID()
        let legacy = """
        {"id":"\(id.uuidString)","created":"2026-01-01T00:00:00Z","modified":"2026-01-02T00:00:00Z","cursor":4,"title":"Legacy"}
        """
        try Data(legacy.utf8).write(to: tempDir.appendingPathComponent("\(id.uuidString).json"))
        try Data("Legacy".utf8).write(to: tempDir.appendingPathComponent("\(id.uuidString).txt"))

        let store = try makeStore()
        let note = store.notes.first(where: { $0.id == id })
        XCTAssertNotNil(note)
        XCTAssertNil(note?.windowFrame)
        XCTAssertEqual(note?.title, "Legacy") // decoded, not regenerated from txt fallback
        XCTAssertEqual(note?.cursor, 4)
    }

    func testSetWindowFrameDoesNotBumpModifiedOrResort() throws {
        let store = try makeStore()
        let older = try store.createNote()
        let newer = try store.createNote()
        try store.save(id: newer.id, contents: "newer", cursor: 0) // newer is first
        let modifiedBefore = store.notes.first(where: { $0.id == older.id })?.modified

        try store.setWindowFrame(id: older.id, frame: "{{0, 0}, {640, 420}}")

        XCTAssertEqual(store.notes.first(where: { $0.id == older.id })?.modified, modifiedBefore)
        XCTAssertEqual(store.notes.first?.id, newer.id) // order unchanged
    }

    func testSetWindowFrameUnknownIDThrowsNotFound() throws {
        let store = try makeStore()
        let bogus = UUID()
        XCTAssertThrowsError(try store.setWindowFrame(id: bogus, frame: nil)) {
            XCTAssertEqual($0 as? NoteStoreError, .notFound(bogus))
        }
    }

    // MARK: - defaultRoot

    func testDefaultRootPointsAtApplicationSupportMeatPadNotes() {
        let root = NoteStore.defaultRoot()
        XCTAssertTrue(root.path.hasSuffix("Application Support/MeatPad/Notes"))
    }

    // MARK: - Folders

    func testFoldersEmptyOnFreshStore() throws {
        let store = try makeStore()
        XCTAssertEqual(store.folders, [])
    }

    func testCreateFolderPersistsAcrossReload() throws {
        let store = try makeStore()
        try store.createFolder("Work")
        try store.createFolder("Recipes")
        XCTAssertEqual(store.folders, ["Work", "Recipes"])
        let reloaded = try makeStore()
        XCTAssertEqual(reloaded.folders, ["Work", "Recipes"])
    }

    func testCreateFolderTrimsAndRejectsEmpty() throws {
        let store = try makeStore()
        try store.createFolder("  Work  ")
        XCTAssertEqual(store.folders, ["Work"])
        XCTAssertThrowsError(try store.createFolder("   ")) { error in
            XCTAssertEqual(error as? NoteStoreError, .invalidFolderName)
        }
    }

    func testCreateFolderRejectsCaseInsensitiveDuplicateAndReservedName() throws {
        let store = try makeStore()
        try store.createFolder("Work")
        XCTAssertThrowsError(try store.createFolder("work")) { error in
            XCTAssertEqual(error as? NoteStoreError, .folderExists("work"))
        }
        XCTAssertThrowsError(try store.createFolder("notes")) { error in
            XCTAssertEqual(error as? NoteStoreError, .invalidFolderName)
        }
    }

    func testRenameFolderRewritesMemberSidecars() throws {
        let store = try makeStore()
        try store.createFolder("Work")
        let member = try store.createNote(in: "Work")
        let outsider = try store.createNote()
        try store.renameFolder("Work", to: "Job")
        XCTAssertEqual(store.folders, ["Job"])
        XCTAssertEqual(store.notes.first(where: { $0.id == member.id })?.folder, "Job")
        XCTAssertNil(store.notes.first(where: { $0.id == outsider.id })?.folder)
        // Persisted, not just in-memory:
        let reloaded = try makeStore()
        XCTAssertEqual(reloaded.notes.first(where: { $0.id == member.id })?.folder, "Job")
    }

    func testRenameFolderUnknownThrows() throws {
        let store = try makeStore()
        XCTAssertThrowsError(try store.renameFolder("Nope", to: "X")) { error in
            XCTAssertEqual(error as? NoteStoreError, .folderNotFound("Nope"))
        }
    }

    func testRenameFolderAllowsCaseChangeOfItself() throws {
        let store = try makeStore()
        try store.createFolder("work")
        try store.renameFolder("work", to: "Work")
        XCTAssertEqual(store.folders, ["Work"])
    }

    func testDeleteFolderTrashesMembersAndKeepsOthers() throws {
        let store = try makeStore()
        try store.createFolder("Work")
        let member = try store.createNote(in: "Work")
        let outsider = try store.createNote()
        try store.deleteFolder("Work")
        XCTAssertEqual(store.folders, [])
        XCTAssertNil(store.notes.first(where: { $0.id == member.id }))
        XCTAssertNotNil(store.notes.first(where: { $0.id == outsider.id }))
        let trashed = tempDir.appendingPathComponent(".trash").appendingPathComponent("\(member.id.uuidString).txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path))
    }

    func testCorruptFoldersFileSelfHealsToEmpty() throws {
        _ = try makeStore()
        try Data("not json".utf8).write(to: tempDir.appendingPathComponent("folders.json"))
        let store = try makeStore()
        XCTAssertEqual(store.folders, [])
    }

    func testLegacySidecarWithoutFolderKeyDecodesToNilFolder() throws {
        let store = try makeStore()
        let note = try store.createNote()
        // Strip the folder key by rewriting the sidecar from legacy-shaped JSON.
        let url = tempDir.appendingPathComponent("\(note.id.uuidString).json")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        object.removeValue(forKey: "folder")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let reloaded = try makeStore()
        XCTAssertNil(reloaded.notes.first(where: { $0.id == note.id })?.folder)
    }

    func testCreateNoteInFolderPersists() throws {
        let store = try makeStore()
        try store.createFolder("Work")
        let note = try store.createNote(in: "Work")
        let reloaded = try makeStore()
        XCTAssertEqual(reloaded.notes.first(where: { $0.id == note.id })?.folder, "Work")
    }

    func testMoveNoteBetweenFoldersAndToDefault() throws {
        let store = try makeStore()
        try store.createFolder("Work")
        let note = try store.createNote()
        try store.move(id: note.id, to: "Work")
        XCTAssertEqual(store.notes.first(where: { $0.id == note.id })?.folder, "Work")
        try store.move(id: note.id, to: nil)
        XCTAssertNil(store.notes.first(where: { $0.id == note.id })?.folder)
    }

    func testMoveDoesNotTouchModified() throws {
        let store = try makeStore()
        try store.createFolder("Work")
        let note = try store.createNote()
        let before = store.notes.first(where: { $0.id == note.id })!.modified
        try store.move(id: note.id, to: "Work")
        XCTAssertEqual(store.notes.first(where: { $0.id == note.id })?.modified, before)
    }

    func testMoveToUnknownFolderThrows() throws {
        let store = try makeStore()
        let note = try store.createNote()
        XCTAssertThrowsError(try store.move(id: note.id, to: "Nope")) { error in
            XCTAssertEqual(error as? NoteStoreError, .folderNotFound("Nope"))
        }
    }

    func testMoveUnknownNoteThrows() throws {
        let store = try makeStore()
        let ghost = UUID()
        XCTAssertThrowsError(try store.move(id: ghost, to: nil)) { error in
            XCTAssertEqual(error as? NoteStoreError, .notFound(ghost))
        }
    }
}
