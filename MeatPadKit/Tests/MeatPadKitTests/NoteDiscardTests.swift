import XCTest
@testable import MeatPadKit

/// "A note left with nothing in it is junk": `discardIfEmpty` and the launch sweep built on it.
@MainActor
final class NoteDiscardTests: XCTestCase {

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

    /// Every file name under the root and its trash that belongs to `id`.
    private func files(of id: UUID) -> [String] {
        let fm = FileManager.default
        return [tempDir!, tempDir.appendingPathComponent(".trash")].flatMap { folder in
            ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix(id.uuidString) }
        }
    }

    func testAnEmptyNoteIsGoneFromTheStoreTheTrashAndTheDisk() throws {
        let store = try makeStore()
        let note = try store.createNote()

        XCTAssertTrue(store.discardIfEmpty(id: note.id))
        XCTAssertFalse(store.notes.contains { $0.id == note.id })
        XCTAssertFalse(store.trashedNotes.contains { $0.id == note.id }, "a discarded note isn't something to restore")
        XCTAssertEqual(files(of: note.id), [])
    }

    func testWhitespaceIsContent() throws {
        let store = try makeStore()
        let note = try store.createNote()
        try store.save(id: note.id, contents: " \n", cursor: 0)

        XCTAssertFalse(store.discardIfEmpty(id: note.id))
        XCTAssertTrue(store.notes.contains { $0.id == note.id })
    }

    func testAnAttachmentIsContent() throws {
        let store = try makeStore()
        let note = try store.createNote()
        try store.addAttachment(id: note.id, data: Data([1]), ext: "png")

        XCTAssertFalse(store.discardIfEmpty(id: note.id))
        XCTAssertTrue(store.notes.contains { $0.id == note.id })
    }

    func testAnUnknownIDIsNotDiscarded() throws {
        XCTAssertFalse(try makeStore().discardIfEmpty(id: UUID()))
    }

    /// A trashed note is the trash's business, not the sweep's.
    func testATrashedEmptyNoteIsLeftAlone() throws {
        let store = try makeStore()
        let note = try store.createNote()
        try store.trash(id: note.id)

        XCTAssertFalse(store.discardIfEmpty(id: note.id))
        XCTAssertTrue(store.trashedNotes.contains { $0.id == note.id })
    }

    func testTheSweepDiscardsEveryEmptyNoteButTheKeptOnes() throws {
        let store = try makeStore()
        let empty = try store.createNote()
        let kept = try store.createNote()
        let written = try store.createNote()
        try store.save(id: written.id, contents: "x", cursor: 1)

        XCTAssertEqual(store.discardEmptyNotes(except: [kept.id]), [empty.id])
        XCTAssertEqual(Set(store.notes.map(\.id)), [kept.id, written.id])
    }

    /// The sweep runs at launch, on what is on disk — a store opened fresh sees the same.
    func testTheSweepWorksOnAFreshlyLoadedStore() throws {
        let empty = try makeStore().createNote()
        let store = try makeStore()

        XCTAssertEqual(store.discardEmptyNotes(except: []), [empty.id])
        XCTAssertEqual(files(of: empty.id), [])
    }
}
