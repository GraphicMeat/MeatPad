import XCTest
@testable import MeatPadKit

@MainActor
final class BoardStoreTests: XCTestCase {

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

    // MARK: - init

    func testInitCreatesRootAndSeedsGlobalColumns() throws {
        let store = try makeStore()
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertEqual(store.globalColumns.map(\.name), ["Todo", "In Progress", "Done"])
        XCTAssertEqual(store.globalColumns.map(\.isDone), [false, false, true])
        XCTAssertTrue(store.boards.isEmpty)
    }

    func testSeededColumnsPersistAcrossReload() throws {
        let ids = try makeStore().globalColumns.map(\.id)
        XCTAssertEqual(try makeStore().globalColumns.map(\.id), ids)
    }

    // MARK: - boards

    func testCreateBoardWritesFileAndAppears() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "project1")

        XCTAssertEqual(board.name, "project1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("\(board.id.uuidString).json").path))
        XCTAssertEqual(store.boards.map(\.id), [board.id])
        XCTAssertEqual(try makeStore().boards.map(\.name), ["project1"])
    }

    func testCreateBoardRejectsEmptyName() throws {
        let store = try makeStore()
        XCTAssertThrowsError(try store.createBoard(name: "   ")) { error in
            XCTAssertEqual(error as? BoardStoreError, .invalidName)
        }
    }

    func testCreateBoardKeepsInsertionOrder() throws {
        let store = try makeStore()
        _ = try store.createBoard(name: "a")
        _ = try store.createBoard(name: "b")
        XCTAssertEqual(store.boards.map(\.name), ["a", "b"])
        XCTAssertEqual(try makeStore().boards.map(\.name), ["a", "b"])
    }

    func testRenameBoardPersists() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "old")
        try store.renameBoard(id: board.id, to: "new")
        XCTAssertEqual(store.boards.first?.name, "new")
        XCTAssertEqual(try makeStore().boards.first?.name, "new")
    }

    func testRenameUnknownBoardThrows() throws {
        let store = try makeStore()
        let unknown = UUID()
        XCTAssertThrowsError(try store.renameBoard(id: unknown, to: "x")) { error in
            XCTAssertEqual(error as? BoardStoreError, .boardNotFound(unknown))
        }
    }

    func testDeleteBoardRemovesFileAndEntry() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "gone")
        try store.deleteBoard(id: board.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("\(board.id.uuidString).json").path))
        XCTAssertTrue(store.boards.isEmpty)
        XCTAssertTrue(try makeStore().boards.isEmpty)
    }

    // MARK: - self-healing load

    func testCorruptBoardFileIsSkippedNotFatal() throws {
        let store = try makeStore()
        let good = try store.createBoard(name: "good")
        let bad = try store.createBoard(name: "bad")
        try Data("not json".utf8).write(to: tempDir.appendingPathComponent("\(bad.id.uuidString).json"))

        XCTAssertEqual(try makeStore().boards.map(\.id), [good.id])
    }

    func testBoardFileMissingFromIndexIsAdopted() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "orphan")
        let index = tempDir.appendingPathComponent("boards.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any])
        json["boardOrder"] = [String]()
        try JSONSerialization.data(withJSONObject: json).write(to: index)

        XCTAssertEqual(try makeStore().boards.map(\.id), [board.id])
    }

    func testIndexEntryWithoutFileIsDropped() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "ghost")
        try FileManager.default.removeItem(at: tempDir.appendingPathComponent("\(board.id.uuidString).json"))

        XCTAssertTrue(try makeStore().boards.isEmpty)
    }

    func testDefaultRootHonoursStorageOverride() throws {
        let suite = "board-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defaults.set(tempDir.path, forKey: NoteStore.storageRootOverrideKey)

        XCTAssertEqual(BoardStore.defaultRoot(defaults: defaults), tempDir.appendingPathComponent("Boards", isDirectory: true))
    }
}
