import XCTest
@testable import MeatPadKit

/// A board's own look: one emoji, or one image file. The rule the whole feature rests on is
/// "one look per board" — setting either side clears the other, so the sidebar never has to
/// decide which of two icons wins.
@MainActor
final class BoardIconTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    private func makeStore() throws -> BoardStore {
        try BoardStore(rootURL: tempDir)
    }

    /// A 1×1 PNG — real bytes, so the file that lands on disk is a real image.
    private var png: Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
    }

    // MARK: - Emoji

    func testSetIconPersistsAcrossReload() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "launch")

        try store.setBoardIcon(id: board.id, emoji: "🚀")

        XCTAssertEqual(store.boards.first?.icon, "🚀")
        XCTAssertEqual(try makeStore().boards.first?.icon, "🚀")
    }

    func testSetIconTrimsAndRejectsEmpty() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "launch")

        try store.setBoardIcon(id: board.id, emoji: "  🚀 ")
        XCTAssertEqual(store.boards.first?.icon, "🚀")

        XCTAssertThrowsError(try store.setBoardIcon(id: board.id, emoji: "   ")) { error in
            XCTAssertEqual(error as? BoardStoreError, .invalidName)
        }
    }

    func testSetIconOnUnknownBoardThrows() throws {
        let store = try makeStore()
        let id = UUID()
        XCTAssertThrowsError(try store.setBoardIcon(id: id, emoji: "🚀")) { error in
            XCTAssertEqual(error as? BoardStoreError, .boardNotFound(id))
        }
    }

    // MARK: - Image

    func testSetImageWritesTheFileAndExposesItsURL() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "launch")

        try store.setBoardImage(id: board.id, data: png, ext: "PNG")

        let name = try XCTUnwrap(store.boards.first?.image)
        XCTAssertTrue(name.hasSuffix(".png"), "extension not normalized: \(name)")
        let url = try XCTUnwrap(store.boardImageURL(board.id))
        XCTAssertEqual(try Data(contentsOf: url), png)
        XCTAssertEqual(try makeStore().boards.first?.image, name, "the name did not survive a reload")
    }

    func testBoardImageURLIsNilWithoutAnImage() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "launch")

        XCTAssertNil(store.boardImageURL(board.id))
        XCTAssertNil(store.boardImageURL(UUID()))
    }

    func testSetImageRejectsAPathForAnExtension() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "launch")

        XCTAssertThrowsError(try store.setBoardImage(id: board.id, data: png, ext: "../../etc"))
        XCTAssertNil(store.boards.first?.image)
    }

    // MARK: - One look per board

    func testAnImageReplacesTheEmoji() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "launch")
        try store.setBoardIcon(id: board.id, emoji: "🚀")

        try store.setBoardImage(id: board.id, data: png, ext: "png")

        XCTAssertNil(store.boards.first?.icon)
        XCTAssertNotNil(store.boards.first?.image)
    }

    func testAnEmojiReplacesTheImageAndDeletesItsFile() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "launch")
        try store.setBoardImage(id: board.id, data: png, ext: "png")
        let url = try XCTUnwrap(store.boardImageURL(board.id))

        try store.setBoardIcon(id: board.id, emoji: "🚀")

        XCTAssertNil(store.boards.first?.image)
        XCTAssertEqual(store.boards.first?.icon, "🚀")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "the old image file was orphaned")
    }

    func testReplacingAnImageDeletesTheOldFile() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "launch")
        try store.setBoardImage(id: board.id, data: png, ext: "png")
        let first = try XCTUnwrap(store.boardImageURL(board.id))

        try store.setBoardImage(id: board.id, data: png, ext: "png")
        let second = try XCTUnwrap(store.boardImageURL(board.id))

        XCTAssertNotEqual(first, second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path), "the replaced image file was orphaned")
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    // MARK: - Clearing

    func testClearBoardIconRemovesBothAndDeletesTheFile() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "launch")
        try store.setBoardImage(id: board.id, data: png, ext: "png")
        let url = try XCTUnwrap(store.boardImageURL(board.id))

        try store.clearBoardIcon(id: board.id)

        XCTAssertNil(store.boards.first?.icon)
        XCTAssertNil(store.boards.first?.image)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(try makeStore().boards.first?.image)
    }

    func testDeletingABoardDeletesItsImageFile() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "launch")
        try store.setBoardImage(id: board.id, data: png, ext: "png")
        let url = try XCTUnwrap(store.boardImageURL(board.id))

        try store.deleteBoard(id: board.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "the board's image outlived the board")
    }

    // MARK: - Older files

    /// A board file written before icons existed has neither key. Optional fields, so it has
    /// to decode unchanged — exactly like `BoardColumn.emoji` and `Card.labelIDs` before it.
    func testABoardFileWrittenBeforeIconsStillDecodes() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let id = UUID()
        let board: [String: Any] = ["id": id.uuidString, "name": "legacy", "extraColumns": [], "cards": []]
        try JSONSerialization.data(withJSONObject: board)
            .write(to: tempDir.appendingPathComponent("\(id.uuidString).json"))

        let store = try makeStore()

        XCTAssertEqual(store.boards.map(\.name), ["legacy"])
        XCTAssertNil(store.boards.first?.icon)
        XCTAssertNil(store.boards.first?.image)
    }
}
