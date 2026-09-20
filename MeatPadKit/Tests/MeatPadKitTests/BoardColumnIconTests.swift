import XCTest
@testable import MeatPadKit

/// A column's own look: one emoji, or one image file — the same "one look" rule as
/// `BoardIconTests`, at the column level. The extra wrinkle here is that a default column's id
/// (Todo/In Progress/Done) is shared across every board's own copy, so `boardID` is what tells
/// the store which board's copy to touch, and files must never leak between them.
@MainActor
final class BoardColumnIconTests: XCTestCase {

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

    /// A second, different image — the cross-board test needs the two files to be
    /// distinguishable by their bytes, not just by name.
    private var otherPNG: Data {
        png + Data("MeatPad column icon test padding".utf8)
    }

    // MARK: - Emoji

    func testSetColumnIconPersistsAcrossReload() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "launch")
        let column = board.extraColumns[0].id

        try store.setColumnIcon(id: column, emoji: "🔥", boardID: board.id)

        XCTAssertEqual(store.boards.first?.extraColumns.first?.emoji, "🔥")
        XCTAssertEqual(try makeStore().boards.first?.extraColumns.first?.emoji, "🔥")
    }

    func testSetColumnIconTrimsAndRejectsEmpty() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "launch")
        let column = board.extraColumns[0].id

        try store.setColumnIcon(id: column, emoji: "  🔥 ", boardID: board.id)
        XCTAssertEqual(store.boards.first?.extraColumns.first?.emoji, "🔥")

        XCTAssertThrowsError(try store.setColumnIcon(id: column, emoji: "   ", boardID: board.id)) { error in
            XCTAssertEqual(error as? BoardStoreError, .invalidName)
        }
    }

    func testSetColumnIconOnUnknownColumnThrows() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "launch")
        let unknown = UUID()
        XCTAssertThrowsError(try store.setColumnIcon(id: unknown, emoji: "🔥", boardID: board.id)) { error in
            XCTAssertEqual(error as? BoardStoreError, .columnNotFound(unknown))
        }
    }

    func testSetColumnIconOnUnknownBoardThrows() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "launch")
        let column = board.extraColumns[0].id
        let unknownBoard = UUID()
        XCTAssertThrowsError(try store.setColumnIcon(id: column, emoji: "🔥", boardID: unknownBoard)) { error in
            XCTAssertEqual(error as? BoardStoreError, .boardNotFound(unknownBoard))
        }
    }

    // MARK: - Image

    func testSetColumnImageWritesTheFileAndExposesItsURL() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "launch")
        let column = board.extraColumns[0].id

        try store.setColumnImage(id: column, data: png, ext: "PNG", boardID: board.id)

        let name = try XCTUnwrap(store.boards.first?.extraColumns.first?.image)
        XCTAssertTrue(name.hasSuffix(".png"), "extension not normalized: \(name)")
        let url = try XCTUnwrap(store.columnImageURL(try XCTUnwrap(store.boards.first?.extraColumns.first)))
        XCTAssertEqual(try Data(contentsOf: url), png)
        XCTAssertEqual(try makeStore().boards.first?.extraColumns.first?.image, name, "the name did not survive a reload")
    }

    func testColumnImageURLIsNilWithoutAnImage() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "launch")

        XCTAssertNil(store.columnImageURL(board.extraColumns[0]))
    }

    /// The trap the pair-keyed lookup exists for: every board's copy of Todo carries the SAME
    /// column id, so an id-keyed lookup would hand the first board's picture to the second's.
    func testTwoBoardsCopiesOfTheSameDefaultColumnKeepTheirOwnImages() throws {
        let store = try makeStore()
        let alpha = try store.createBoard(name: "alpha")
        let beta = try store.createBoard(name: "beta")
        let column = alpha.extraColumns[0].id
        XCTAssertEqual(column, beta.extraColumns[0].id, "the default columns stopped sharing an id")

        try store.setColumnImage(id: column, data: png, ext: "png", boardID: alpha.id)
        try store.setColumnImage(id: column, data: otherPNG, ext: "png", boardID: beta.id)

        let alphaColumn = try XCTUnwrap(store.boards.first { $0.id == alpha.id }?.extraColumns.first)
        let betaColumn = try XCTUnwrap(store.boards.first { $0.id == beta.id }?.extraColumns.first)
        XCTAssertNotEqual(alphaColumn.image, betaColumn.image, "the two boards share one image name")
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(store.columnImageURL(alphaColumn))), png)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(store.columnImageURL(betaColumn))), otherPNG)
    }

    // MARK: - One look per column

    func testAnImageReplacesTheEmoji() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "launch")
        let column = board.extraColumns[0].id
        try store.setColumnIcon(id: column, emoji: "🔥", boardID: board.id)

        try store.setColumnImage(id: column, data: png, ext: "png", boardID: board.id)

        XCTAssertNil(store.boards.first?.extraColumns.first?.emoji)
        XCTAssertNotNil(store.boards.first?.extraColumns.first?.image)
    }

    func testAnEmojiReplacesTheImageAndDeletesItsFile() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "launch")
        let column = board.extraColumns[0].id
        try store.setColumnImage(id: column, data: png, ext: "png", boardID: board.id)
        let url = try XCTUnwrap(store.columnImageURL(try XCTUnwrap(store.boards.first?.extraColumns.first)))

        try store.setColumnIcon(id: column, emoji: "🔥", boardID: board.id)

        XCTAssertNil(store.boards.first?.extraColumns.first?.image)
        XCTAssertEqual(store.boards.first?.extraColumns.first?.emoji, "🔥")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "the old image file was orphaned")
    }

    // MARK: - Clearing

    func testClearColumnIconRemovesBothAndDeletesTheFile() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "launch")
        let column = board.extraColumns[0].id
        try store.setColumnImage(id: column, data: png, ext: "png", boardID: board.id)
        let url = try XCTUnwrap(store.columnImageURL(try XCTUnwrap(store.boards.first?.extraColumns.first)))

        try store.clearColumnIcon(id: column, boardID: board.id)

        XCTAssertNil(store.boards.first?.extraColumns.first?.emoji)
        XCTAssertNil(store.boards.first?.extraColumns.first?.image)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(try makeStore().boards.first?.extraColumns.first?.image)
    }

    // MARK: - Cross-board isolation

    /// Todo shares its id across every board (`BoardStore.defaultColumnTemplate`) — setting or
    /// clearing one board's copy of it must never touch another board's copy of the same id.
    func testSameIDColumnIconsOnDifferentBoardsDoNotTouchEachOther() throws {
        let store = try makeStore()
        let a = try store.createBoard(name: "A")
        let b = try store.createBoard(name: "B")
        let todoID = a.extraColumns[0].id
        XCTAssertEqual(todoID, b.extraColumns[0].id, "test assumption: default columns share an id")

        try store.setColumnImage(id: todoID, data: png, ext: "png", boardID: a.id)
        try store.setColumnIcon(id: todoID, emoji: "🔥", boardID: b.id)

        let aColumn = store.boards.first(where: { $0.id == a.id })!.extraColumns[0]
        let bColumn = store.boards.first(where: { $0.id == b.id })!.extraColumns[0]
        XCTAssertNotNil(aColumn.image)
        XCTAssertNil(aColumn.emoji)
        XCTAssertEqual(bColumn.emoji, "🔥")
        XCTAssertNil(bColumn.image)

        // Clearing A's copy must not disturb B's, and vice versa.
        try store.clearColumnIcon(id: todoID, boardID: a.id)
        XCTAssertNil(store.boards.first(where: { $0.id == a.id })!.extraColumns[0].image)
        XCTAssertEqual(store.boards.first(where: { $0.id == b.id })!.extraColumns[0].emoji, "🔥")
    }
}
