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

    func testInitCreatesRootAndSeedsNewBoardsWithDefaultColumns() throws {
        let store = try makeStore()
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertTrue(store.boards.isEmpty)

        let board = try store.createBoard(name: "a")
        XCTAssertEqual(board.extraColumns.map(\.name), ["Todo", "In Progress", "Done"])
        XCTAssertEqual(board.extraColumns.map(\.isDone), [false, false, true])
    }

    func testDefaultColumnIdsAreStableSoAllBoardsCanPoolByThem() throws {
        let store = try makeStore()
        let a = try store.createBoard(name: "a")
        let b = try store.createBoard(name: "b")
        // Same three ids on every board — what lets the All Boards overview pool cards from
        // different boards' "Todo" into one bucket without a shared, mutable column list.
        XCTAssertEqual(a.extraColumns.map(\.id), b.extraColumns.map(\.id))
        XCTAssertEqual(a.extraColumns.map(\.id), try makeStore().boards[0].extraColumns.map(\.id))
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

    // MARK: - cards

    private func makeBoard(_ store: BoardStore) throws -> Board {
        try store.createBoard(name: "project1")
    }

    func testAddCardLandsInColumnAndPersists() throws {
        let store = try makeStore()
        let board = try makeBoard(store)
        let todo = board.extraColumns[0]
        let card = try store.addCard(boardID: board.id, columnID: todo.id, title: "ship it")

        XCTAssertEqual(card.title, "ship it")
        XCTAssertEqual(card.columnID, todo.id)
        XCTAssertEqual(store.cards(in: store.boards[0], column: todo.id).map(\.id), [card.id])
        XCTAssertEqual(try makeStore().boards[0].cards.map(\.title), ["ship it"])
    }

    func testAddCardRejectsEmptyTitleAndUnknownColumn() throws {
        let store = try makeStore()
        let board = try makeBoard(store)
        XCTAssertThrowsError(try store.addCard(boardID: board.id, columnID: board.extraColumns[0].id, title: " ")) {
            XCTAssertEqual($0 as? BoardStoreError, .invalidName)
        }
        let unknown = UUID()
        XCTAssertThrowsError(try store.addCard(boardID: board.id, columnID: unknown, title: "x")) {
            XCTAssertEqual($0 as? BoardStoreError, .columnNotFound(unknown))
        }
    }

    func testUpdateCardBumpsModifiedAndPersists() throws {
        let store = try makeStore()
        let board = try makeBoard(store)
        var card = try store.addCard(boardID: board.id, columnID: board.extraColumns[0].id, title: "a")
        let before = card.modified
        card.title = "b"
        card.body = "detail"
        card.due = Date(timeIntervalSince1970: 1_800_000_000)
        try store.updateCard(boardID: board.id, card: card)

        let stored = store.boards[0].cards[0]
        XCTAssertEqual(stored.title, "b")
        XCTAssertEqual(stored.body, "detail")
        XCTAssertEqual(stored.due, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertGreaterThanOrEqual(stored.modified, before)
        XCTAssertEqual(try makeStore().boards[0].cards[0].body, "detail")
    }

    func testDeleteCardRemovesItEverywhere() throws {
        let store = try makeStore()
        let board = try makeBoard(store)
        let card = try store.addCard(boardID: board.id, columnID: board.extraColumns[0].id, title: "a")
        try store.deleteCard(boardID: board.id, cardID: card.id)

        XCTAssertTrue(store.boards[0].cards.isEmpty)
        XCTAssertTrue(try makeStore().boards[0].cards.isEmpty)
    }

    func testMoveCardChangesColumnAndPosition() throws {
        let store = try makeStore()
        let board = try makeBoard(store)
        let todo = board.extraColumns[0].id
        let doing = board.extraColumns[1].id
        let a = try store.addCard(boardID: board.id, columnID: todo, title: "a")
        _ = try store.addCard(boardID: board.id, columnID: todo, title: "b")
        _ = try store.addCard(boardID: board.id, columnID: doing, title: "c")

        try store.moveCard(id: a.id, boardID: board.id, toColumn: doing, index: 0)
        XCTAssertEqual(store.cards(in: store.boards[0], column: doing).map(\.title), ["a", "c"])
        XCTAssertEqual(store.cards(in: store.boards[0], column: todo).map(\.title), ["b"])

        try store.moveCard(id: a.id, boardID: board.id, toColumn: doing, index: 99)
        XCTAssertEqual(store.cards(in: store.boards[0], column: doing).map(\.title), ["c", "a"])
        XCTAssertEqual(try makeStore().boards[0].cards.count, 3)
    }

    func testMoveCardWithinSameColumnReorders() throws {
        let store = try makeStore()
        let board = try makeBoard(store)
        let todo = board.extraColumns[0].id
        let a = try store.addCard(boardID: board.id, columnID: todo, title: "a")
        _ = try store.addCard(boardID: board.id, columnID: todo, title: "b")
        _ = try store.addCard(boardID: board.id, columnID: todo, title: "c")

        try store.moveCard(id: a.id, boardID: board.id, toColumn: todo, index: 2)
        XCTAssertEqual(store.cards(in: store.boards[0], column: todo).map(\.title), ["b", "c", "a"])
    }

    func testMoveCardRejectsUnknownColumnAndCard() throws {
        let store = try makeStore()
        let board = try makeBoard(store)
        let card = try store.addCard(boardID: board.id, columnID: board.extraColumns[0].id, title: "a")
        let unknownColumn = UUID()
        XCTAssertThrowsError(try store.moveCard(id: card.id, boardID: board.id, toColumn: unknownColumn, index: 0)) {
            XCTAssertEqual($0 as? BoardStoreError, .columnNotFound(unknownColumn))
        }
        let unknownCard = UUID()
        XCTAssertThrowsError(try store.moveCard(id: unknownCard, boardID: board.id, toColumn: board.extraColumns[1].id, index: 0)) {
            XCTAssertEqual($0 as? BoardStoreError, .cardNotFound(unknownCard))
        }
    }

    // MARK: - column editing

    /// The bug this store rewrite fixes: deleting a board's own copy of a once-shared default
    /// column must never touch any other board's copy, however the same the two look.
    func testDeletingADefaultColumnOnOneBoardNeverTouchesAnotherBoard() throws {
        let store = try makeStore()
        let a = try store.createBoard(name: "a")
        let b = try store.createBoard(name: "b")
        try store.deleteColumn(id: a.extraColumns[0].id, boardID: a.id)

        XCTAssertEqual(store.boards[0].extraColumns.map(\.name), ["In Progress", "Done"])
        XCTAssertEqual(store.boards[1].extraColumns.map(\.name), ["Todo", "In Progress", "Done"])
        let reloaded = try makeStore()
        XCTAssertEqual(reloaded.boards[0].extraColumns.map(\.name), ["In Progress", "Done"])
        XCTAssertEqual(reloaded.boards[1].extraColumns.map(\.name), ["Todo", "In Progress", "Done"])
    }

    /// The old shared-column-list format (`globalColumns` in `boards.json`, no per-board
    /// copies) migrates into every board owning its own columns, remapped onto the fixed
    /// `defaultColumnTemplate` ids — and a default the user had already deleted (so it's
    /// missing from the legacy list) comes back structurally, empty, rather than staying gone.
    func testMigratesLegacyGlobalColumnsIntoEveryBoardAndReseedsAMissingDefault() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let boardID = UUID()
        let todoLegacyID = UUID()
        let doneLegacyID = UUID()
        let cardID = UUID()
        let boardJSON: [String: Any] = [
            "id": boardID.uuidString, "name": "legacy", "extraColumns": [],
            "cards": [[
                "id": cardID.uuidString, "title": "x", "columnID": doneLegacyID.uuidString,
                "created": "2026-01-01T00:00:00Z", "modified": "2026-01-01T00:00:00Z",
            ]],
        ]
        try JSONSerialization.data(withJSONObject: boardJSON)
            .write(to: tempDir.appendingPathComponent("\(boardID.uuidString).json"))
        let indexJSON: [String: Any] = [
            "boardOrder": [boardID.uuidString],
            "globalColumns": [
                ["id": todoLegacyID.uuidString, "name": "Todo", "isDone": false, "emoji": "📋"],
                ["id": doneLegacyID.uuidString, "name": "Shipped", "isDone": true, "emoji": "✅"],
            ],
        ]
        try JSONSerialization.data(withJSONObject: indexJSON).write(to: tempDir.appendingPathComponent("boards.json"))

        let store = try makeStore()
        let board = store.boards[0]
        XCTAssertEqual(board.extraColumns.map(\.name), ["Todo", "In Progress", "Shipped"])
        // The card that was sitting in the renamed "Shipped" (legacy Done) column follows it.
        XCTAssertEqual(board.cards.first?.columnID, board.extraColumns[2].id)
        // Reloading again must not re-run the migration — the legacy key is gone from disk now.
        XCTAssertEqual(try makeStore().boards[0].extraColumns.map(\.name), ["Todo", "In Progress", "Shipped"])
    }

    func testAddExtraColumnIsBoardLocalAndRendersAfterGlobals() throws {
        let store = try makeStore()
        let a = try store.createBoard(name: "a")
        _ = try store.createBoard(name: "b")
        try store.addExtraColumn(boardID: a.id, name: "Blocked")

        XCTAssertEqual(store.columns(for: store.boards[0]).map(\.name), ["Todo", "In Progress", "Done", "Blocked"])
        XCTAssertEqual(store.columns(for: store.boards[1]).map(\.name), ["Todo", "In Progress", "Done"])
        XCTAssertEqual(try makeStore().boards[0].extraColumns.map(\.name), ["Blocked"])
    }

    func testRenameColumnKeepsCardMembership() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "a")
        let todo = board.extraColumns[0].id
        let card = try store.addCard(boardID: board.id, columnID: todo, title: "x")
        try store.renameColumn(id: todo, to: "Backlog", boardID: board.id)

        XCTAssertEqual(store.boards[0].extraColumns[0].name, "Backlog")
        XCTAssertEqual(store.cards(in: store.boards[0], column: todo).map(\.id), [card.id])
        XCTAssertEqual(try makeStore().boards[0].extraColumns[0].name, "Backlog")
    }

    func testSetColumnDoneFlagsAndPersists() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "a")
        let todo = board.extraColumns[0].id
        try store.setColumnDone(id: todo, true, boardID: board.id)

        XCTAssertTrue(store.boards[0].extraColumns[0].isDone)
        XCTAssertTrue(try makeStore().boards[0].extraColumns[0].isDone)
    }

    func testDeleteColumnReassignsItsCardsToTheBoardsFirstRemainingColumn() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "a")
        let todo = board.extraColumns[0].id
        let doing = board.extraColumns[1].id
        let card = try store.addCard(boardID: board.id, columnID: doing, title: "x")
        try store.deleteColumn(id: doing, boardID: board.id)

        XCTAssertEqual(store.boards[0].extraColumns.map(\.name), ["Todo", "Done"])
        XCTAssertEqual(store.cards(in: store.boards[0], column: todo).map(\.id), [card.id])
        XCTAssertEqual(try makeStore().boards[0].cards[0].columnID, todo)
    }

    func testDeleteExtraColumnReassignsToTheBoardsFirstRemainingColumn() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "a")
        try store.addExtraColumn(boardID: board.id, name: "Blocked")
        let blocked = store.boards[0].extraColumns[3].id
        let card = try store.addCard(boardID: board.id, columnID: blocked, title: "x")
        try store.deleteColumn(id: blocked, boardID: board.id)

        XCTAssertEqual(store.boards[0].extraColumns.map(\.name), ["Todo", "In Progress", "Done"])
        XCTAssertEqual(store.boards[0].cards.first(where: { $0.id == card.id })?.columnID, store.boards[0].extraColumns[0].id)
    }

    func testCannotDeleteABoardsLastColumn() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "a")
        try store.deleteColumn(id: board.extraColumns[2].id, boardID: board.id)
        try store.deleteColumn(id: board.extraColumns[1].id, boardID: board.id)

        XCTAssertThrowsError(try store.deleteColumn(id: board.extraColumns[0].id, boardID: board.id)) {
            XCTAssertEqual($0 as? BoardStoreError, .lastColumn)
        }
    }

    // MARK: - column order

    func testMoveColumnOnBoardInterleavesGlobalsAndExtrasWithoutTouchingOtherBoards() throws {
        let store = try makeStore()
        let a = try store.createBoard(name: "A")
        let b = try store.createBoard(name: "B")
        try store.addExtraColumn(boardID: a.id, name: "Extra")
        let extra = store.boards[0].extraColumns[0].id
        try store.moveColumn(id: extra, to: 0, onBoard: a.id)
        XCTAssertEqual(store.columns(for: store.boards[0]).map(\.name), ["Extra", "Todo", "In Progress", "Done"])
        XCTAssertEqual(store.columns(for: store.boards[1]).map(\.name), ["Todo", "In Progress", "Done"])
        XCTAssertEqual(try makeStore().columns(for: try makeStore().boards[0]).map(\.name), ["Extra", "Todo", "In Progress", "Done"])
        _ = b
    }

    func testColumnAddedAfterCustomOrderAppendsAndDeletedOneDisappears() throws {
        let store = try makeStore()
        let a = try store.createBoard(name: "A")
        let done = a.extraColumns[2].id
        try store.moveColumn(id: done, to: 0, onBoard: a.id)
        try store.addExtraColumn(boardID: a.id, name: "Later")
        try store.deleteColumn(id: store.boards[0].extraColumns[1].id, boardID: a.id)   // In Progress
        XCTAssertEqual(store.columns(for: store.boards[0]).map(\.name), ["Done", "Todo", "Later"])
    }

    func testMoveColumnClampsToTheEndsOfTheBoardsOwnOrder() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "A")
        let todo = board.extraColumns[0].id
        try store.moveColumn(id: todo, to: 99, onBoard: board.id)
        XCTAssertEqual(store.columns(for: store.boards[0]).map(\.name), ["In Progress", "Done", "Todo"])
        XCTAssertEqual(try makeStore().columns(for: try makeStore().boards[0]).map(\.name), ["In Progress", "Done", "Todo"])
    }

    func testMoveUnknownColumnThrows() throws {
        let store = try makeStore()
        let a = try store.createBoard(name: "A")
        XCTAssertThrowsError(try store.moveColumn(id: UUID(), to: 0, onBoard: a.id))
    }

    func testBoardFileWithoutColumnOrderDecodes() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let id = UUID()
        let board: [String: Any] = ["id": id.uuidString, "name": "legacy", "extraColumns": [], "cards": []]
        try JSONSerialization.data(withJSONObject: board)
            .write(to: tempDir.appendingPathComponent("\(id.uuidString).json"))
        let store = try makeStore()
        XCTAssertNil(store.boards.first?.columnOrder)
        XCTAssertEqual(store.columns(for: store.boards[0]).map(\.name), ["Todo", "In Progress", "Done"])
    }

    // MARK: - note link + due reminders

    func testCardForNoteFindsAndMisses() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "a")
        var card = try store.addCard(boardID: board.id, columnID: board.extraColumns[0].id, title: "x")
        let noteID = UUID()
        card.noteID = noteID
        try store.updateCard(boardID: board.id, card: card)

        XCTAssertEqual(store.card(forNote: noteID)?.card.id, card.id)
        XCTAssertEqual(store.card(forNote: noteID)?.board.id, board.id)
        XCTAssertNil(store.card(forNote: UUID()))
    }

    func testPendingDueRemindersSkipsPastDoneAndUndated() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "a")
        let todo = board.extraColumns[0].id
        let done = board.extraColumns[2].id
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        var future = try store.addCard(boardID: board.id, columnID: todo, title: "future")
        future.due = now.addingTimeInterval(3600)
        try store.updateCard(boardID: board.id, card: future)

        var past = try store.addCard(boardID: board.id, columnID: todo, title: "past")
        past.due = now.addingTimeInterval(-3600)
        try store.updateCard(boardID: board.id, card: past)

        var finished = try store.addCard(boardID: board.id, columnID: done, title: "finished")
        finished.due = now.addingTimeInterval(7200)
        try store.updateCard(boardID: board.id, card: finished)

        _ = try store.addCard(boardID: board.id, columnID: todo, title: "undated")

        let reminders = store.pendingDueReminders(now: now)
        XCTAssertEqual(reminders.map(\.title), ["future"])
        XCTAssertEqual(reminders.first?.cardID, future.id)
        XCTAssertEqual(reminders.first?.boardID, board.id)
        XCTAssertEqual(reminders.first?.due, now.addingTimeInterval(3600))
    }

    func testPendingDueRemindersHonoursExtraColumnDoneFlag() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "a")
        try store.addExtraColumn(boardID: board.id, name: "Shipped")
        let shipped = store.boards[0].extraColumns[0].id
        try store.setColumnDone(id: shipped, true, boardID: board.id)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var card = try store.addCard(boardID: board.id, columnID: shipped, title: "x")
        card.due = now.addingTimeInterval(3600)
        try store.updateCard(boardID: board.id, card: card)

        XCTAssertTrue(store.pendingDueReminders(now: now).isEmpty)
    }

    func testPendingDueRemindersSpanEveryBoard() throws {
        let store = try makeStore()
        let a = try store.createBoard(name: "a")
        let b = try store.createBoard(name: "b")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for board in [a, b] {
            var card = try store.addCard(boardID: board.id, columnID: board.extraColumns[0].id, title: board.name)
            card.due = now.addingTimeInterval(60)
            try store.updateCard(boardID: board.id, card: card)
        }

        XCTAssertEqual(store.pendingDueReminders(now: now).map(\.title).sorted(), ["a", "b"])
    }

    // MARK: - column emoji

    func testSeedsDefaultColumnEmoji() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "a")
        XCTAssertEqual(board.extraColumns.map(\.emoji), ["📋", "🚧", "✅"])
    }

    /// A legacy store from before columns carried emoji at all has none in its
    /// `globalColumns` JSON. The migration heals them by role (same heuristic the old
    /// in-place heal used) before matching legacy columns onto the new per-board defaults —
    /// otherwise the emoji-keyed match in `migrateLegacyGlobalColumns` couldn't identify
    /// Todo/In Progress/Done at all.
    func testMigrationHealsMissingEmojiOnAVeryOldStoreBeforeMatching() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let boardID = UUID()
        let boardJSON: [String: Any] = ["id": boardID.uuidString, "name": "legacy", "extraColumns": [], "cards": []]
        try JSONSerialization.data(withJSONObject: boardJSON)
            .write(to: tempDir.appendingPathComponent("\(boardID.uuidString).json"))
        let indexJSON: [String: Any] = [
            "boardOrder": [boardID.uuidString],
            "globalColumns": [
                ["id": UUID().uuidString, "name": "Todo", "isDone": false],
                ["id": UUID().uuidString, "name": "In Progress", "isDone": false],
                ["id": UUID().uuidString, "name": "Done", "isDone": true],
            ],
        ]
        try JSONSerialization.data(withJSONObject: indexJSON).write(to: tempDir.appendingPathComponent("boards.json"))

        let healed = try makeStore()
        XCTAssertEqual(healed.boards[0].extraColumns.map(\.emoji), ["📋", "🚧", "✅"])
        // Reloading again must not re-run the migration — the legacy key is gone from disk.
        try healed.renameColumn(id: healed.boards[0].extraColumns[0].id, to: "Backlog", boardID: healed.boards[0].id)
        let reloaded = try makeStore().boards[0].extraColumns
        XCTAssertEqual(reloaded.map(\.name), ["Backlog", "In Progress", "Done"])
        XCTAssertEqual(reloaded.map(\.emoji), ["📋", "🚧", "✅"])
    }

    func testExtraColumnsHaveNoEmojiByDefault() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "a")
        try store.addExtraColumn(boardID: board.id, name: "Blocked")
        XCTAssertNil(store.boards[0].extraColumns[0].emoji)
    }

    // MARK: - labels

    func testCreateLabelPersistsAcrossReload() throws {
        let store = try makeStore()
        let label = try store.createLabel(name: "Bug")
        XCTAssertEqual(store.labels.map(\.name), ["Bug"])
        XCTAssertEqual(try makeStore().labels, [label])
    }

    func testCreateLabelTrimsAndRejectsEmptyName() throws {
        let store = try makeStore()
        XCTAssertEqual(try store.createLabel(name: "  Sunday  ").name, "Sunday")
        XCTAssertThrowsError(try store.createLabel(name: "   ")) {
            XCTAssertEqual($0 as? BoardStoreError, .invalidName)
        }
    }

    func testEveryPaletteColorIsUsedBeforeAnyRepeats() throws {
        let store = try makeStore()
        for i in 0..<CardLabel.palette.count { _ = try store.createLabel(name: "l\(i)") }
        XCTAssertEqual(Set(store.labels.map(\.color)).count, CardLabel.palette.count)
        XCTAssertTrue(store.labels.allSatisfy { CardLabel.palette.contains($0.color) })
    }

    func testColorsWrapEvenlyOncePaletteIsExhausted() throws {
        let store = try makeStore()
        for i in 0...CardLabel.palette.count { _ = try store.createLabel(name: "l\(i)") }
        let counts = Dictionary(grouping: store.labels, by: \.color).mapValues(\.count)
        XCTAssertEqual(counts.values.max(), 2)
        XCTAssertEqual(counts.values.filter { $0 == 2 }.count, 1)
    }

    func testCreateLabelHonoursAPickedColor() throws {
        let store = try makeStore()
        let picked = CardLabel.palette[7]
        XCTAssertEqual(try store.createLabel(name: "Picked", color: picked).color, picked)
        XCTAssertEqual(try makeStore().labels.map(\.color), [picked])
    }

    /// The form opens on this swatch, so it has to be the colour the store would have
    /// assigned itself — creating without touching the swatches must not change behaviour.
    func testSuggestedColorIsWhatAnUncolouredCreateWouldUse() throws {
        let store = try makeStore()
        _ = try store.createLabel(name: "First")
        let suggested = store.suggestedLabelColor
        XCTAssertEqual(try store.createLabel(name: "Second").color, suggested)
    }

    // MARK: - board colours

    func testEachBoardGetsItsOwnColor() throws {
        let store = try makeStore()
        let ids = try (0..<4).map { try store.createBoard(name: "b\($0)").id }
        let colors = ids.map { store.color(forBoard: $0) }
        XCTAssertEqual(Set(colors).count, ids.count)
        XCTAssertTrue(colors.allSatisfy { CardLabel.palette.contains($0) })
    }

    func testBoardColorIsStableAcrossReload() throws {
        let store = try makeStore()
        let id = try store.createBoard(name: "Only").id
        XCTAssertEqual(try makeStore().color(forBoard: id), store.color(forBoard: id))
    }

    func testRenameAndRecolorLabelPersist() throws {
        let store = try makeStore()
        let label = try store.createLabel(name: "Bug")
        let cyan = try XCTUnwrap(RGBAColor(hex: "#33CCFF"))
        try store.renameLabel(id: label.id, to: "Defect")
        try store.setLabelColor(id: label.id, cyan)
        let reloaded = try makeStore()
        XCTAssertEqual(reloaded.labels.first?.name, "Defect")
        XCTAssertEqual(reloaded.labels.first?.color, cyan)
    }

    func testLabelOpsOnUnknownIDThrow() throws {
        let store = try makeStore()
        let ghost = UUID()
        XCTAssertThrowsError(try store.renameLabel(id: ghost, to: "x")) {
            XCTAssertEqual($0 as? BoardStoreError, .labelNotFound(ghost))
        }
        XCTAssertThrowsError(try store.setLabelColor(id: ghost, RGBAColor(r: 0, g: 0, b: 0)))
        XCTAssertThrowsError(try store.deleteLabel(id: ghost))
    }

    func testCardKeepsAssignedLabelsAcrossReload() throws {
        let store = try makeStore()
        let label = try store.createLabel(name: "Bug")
        let board = try store.createBoard(name: "b")
        var card = try store.addCard(boardID: board.id, columnID: board.extraColumns[0].id, title: "c")
        card.labelIDs = [label.id]
        try store.updateCard(boardID: board.id, card: card)
        XCTAssertEqual(try makeStore().boards[0].cards[0].labelIDs, [label.id])
    }

    func testDeletingALabelStripsItFromEveryCard() throws {
        let store = try makeStore()
        let keep = try store.createLabel(name: "Keep")
        let drop = try store.createLabel(name: "Drop")
        let board = try store.createBoard(name: "b")
        var card = try store.addCard(boardID: board.id, columnID: board.extraColumns[0].id, title: "c")
        card.labelIDs = [keep.id, drop.id]
        try store.updateCard(boardID: board.id, card: card)

        try store.deleteLabel(id: drop.id)

        XCTAssertEqual(store.labels.map(\.id), [keep.id])
        XCTAssertEqual(try makeStore().boards[0].cards[0].labelIDs, [keep.id])
    }

    // MARK: - label filtering

    func testEmptyFilterMatchesEveryCard() throws {
        XCTAssertTrue(Card(title: "c", columnID: UUID()).matches(labels: []))
    }

    func testFilterMatchesAnySelectedLabelNotAllOfThem() throws {
        let (a, b, c) = (UUID(), UUID(), UUID())
        var card = Card(title: "c", columnID: UUID())
        card.labelIDs = [a]
        XCTAssertTrue(card.matches(labels: [a, b]))
        XCTAssertFalse(card.matches(labels: [b, c]))
    }

    func testUnlabelledCardIsHiddenByAnyFilter() throws {
        XCTAssertFalse(Card(title: "c", columnID: UUID()).matches(labels: [UUID()]))
    }

    // MARK: - card colour

    func testCardColorPersistsAcrossReload() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "b")
        var card = try store.addCard(boardID: board.id, columnID: board.extraColumns[0].id, title: "c")
        card.color = CardLabel.palette[4]
        try store.updateCard(boardID: board.id, card: card)

        XCTAssertEqual(try makeStore().boards[0].cards[0].color, CardLabel.palette[4])
    }

    func testClearingCardColorPersistsAsNil() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "b")
        var card = try store.addCard(boardID: board.id, columnID: board.extraColumns[0].id, title: "c")
        card.color = CardLabel.palette[0]
        try store.updateCard(boardID: board.id, card: card)
        card.color = nil
        try store.updateCard(boardID: board.id, card: card)

        XCTAssertNil(try makeStore().boards[0].cards[0].color)
    }

    // MARK: - text search

    func testEmptyQueryMatchesEveryCard() throws {
        XCTAssertTrue(Card(title: "c", columnID: UUID()).matches(labels: [], text: ""))
        XCTAssertTrue(Card(title: "c", columnID: UUID()).matches(labels: [], text: "   "))
    }

    func testQueryMatchesTitleSubstringIgnoringCaseAndDiacritics() throws {
        let card = Card(title: "Réfactor the Parser", columnID: UUID())
        XCTAssertTrue(card.matches(labels: [], text: "parser"))
        XCTAssertTrue(card.matches(labels: [], text: "refactor"))
        XCTAssertTrue(card.matches(labels: [], text: "or the Par"))
        XCTAssertFalse(card.matches(labels: [], text: "lexer"))
    }

    func testQueryMatchesBody() throws {
        let card = Card(title: "Ship it", body: "blocked on notarization", columnID: UUID())
        XCTAssertTrue(card.matches(labels: [], text: "notarization"))
        XCTAssertFalse(Card(title: "Ship it", columnID: UUID()).matches(labels: [], text: "notarization"))
    }

    /// Both filters narrow: a card the chips already dropped stays dropped however well it
    /// matches the text, and vice versa.
    func testLabelFilterAndQueryBothHaveToPass() throws {
        let (a, b) = (UUID(), UUID())
        var card = Card(title: "Fix crash", columnID: UUID())
        card.labelIDs = [a]
        XCTAssertTrue(card.matches(labels: [a], text: "crash"))
        XCTAssertFalse(card.matches(labels: [a], text: "leak"))
        XCTAssertFalse(card.matches(labels: [b], text: "crash"))
    }

    // MARK: - legacy files

    func testStoreWrittenBeforeLabelsStillDecodes() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "b")
        _ = try store.addCard(boardID: board.id, columnID: board.extraColumns[0].id, title: "c")

        let boardURL = tempDir.appendingPathComponent("\(board.id.uuidString).json")
        var boardJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: boardURL)) as? [String: Any])
        var cards = try XCTUnwrap(boardJSON["cards"] as? [[String: Any]])
        for i in cards.indices {
            cards[i].removeValue(forKey: "labelIDs")
            cards[i].removeValue(forKey: "color")
        }
        boardJSON["cards"] = cards
        try JSONSerialization.data(withJSONObject: boardJSON).write(to: boardURL)

        let indexURL = tempDir.appendingPathComponent("boards.json")
        var indexJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any])
        indexJSON.removeValue(forKey: "labels")
        try JSONSerialization.data(withJSONObject: indexJSON).write(to: indexURL)

        let reloaded = try makeStore()
        XCTAssertTrue(reloaded.labels.isEmpty)
        XCTAssertEqual(reloaded.boards[0].cards.count, 1)
        XCTAssertNil(reloaded.boards[0].cards[0].labelIDs)
        XCTAssertNil(reloaded.boards[0].cards[0].color)
    }

    // MARK: - undo

    /// Each mutation is its own group whatever the run loop is doing, so a unit test (no
    /// event loop) sees the same one-step-per-edit granularity the app does.
    private func undoable(_ store: BoardStore) -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        return undo
    }

    func testUpdateCardUndoRestoresThePreviousCardAndRedoReapplies() throws {
        let store = try makeStore()
        let undo = undoable(store)
        let board = try store.createBoard(name: "b")
        var card = try store.addCard(boardID: board.id, columnID: board.extraColumns[0].id, title: "before")
        card.title = "after"
        card.body = "notes"
        try store.updateCard(boardID: board.id, card: card)

        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(store.boards[0].cards[0].title, "before")
        XCTAssertNil(store.boards[0].cards[0].body)

        XCTAssertTrue(undo.canRedo)
        undo.redo()
        XCTAssertEqual(store.boards[0].cards[0].title, "after")
        XCTAssertEqual(store.boards[0].cards[0].body, "notes")
    }

    func testDeleteCardUndoPutsItBackAtTheSamePosition() throws {
        let store = try makeStore()
        let undo = undoable(store)
        let board = try store.createBoard(name: "b")
        let column = board.extraColumns[0].id
        for title in ["a", "b", "c"] { _ = try store.addCard(boardID: board.id, columnID: column, title: title) }
        let middle = store.boards[0].cards[1]

        try store.deleteCard(boardID: board.id, cardID: middle.id)
        XCTAssertEqual(store.boards[0].cards.map(\.title), ["a", "c"])

        undo.undo()
        XCTAssertEqual(store.boards[0].cards.map(\.title), ["a", "b", "c"])
        XCTAssertEqual(store.boards[0].cards[1].id, middle.id)

        undo.redo()
        XCTAssertEqual(store.boards[0].cards.map(\.title), ["a", "c"])
    }

    func testMoveCardUndoReturnsItToItsColumnAndPosition() throws {
        let store = try makeStore()
        let undo = undoable(store)
        let board = try store.createBoard(name: "b")
        let todo = board.extraColumns[0].id
        let doing = board.extraColumns[1].id
        for title in ["a", "b", "c"] { _ = try store.addCard(boardID: board.id, columnID: todo, title: title) }
        let b = store.boards[0].cards[1]

        try store.moveCard(id: b.id, boardID: board.id, toColumn: doing, index: 0)
        XCTAssertEqual(store.cards(in: store.boards[0], column: doing).map(\.title), ["b"])

        undo.undo()
        XCTAssertEqual(store.cards(in: store.boards[0], column: todo).map(\.title), ["a", "b", "c"])
        XCTAssertTrue(store.cards(in: store.boards[0], column: doing).isEmpty)
    }

    func testAddCardUndoRemovesIt() throws {
        let store = try makeStore()
        let undo = undoable(store)
        let board = try store.createBoard(name: "b")
        let card = try store.addCard(boardID: board.id, columnID: board.extraColumns[0].id, title: "x")

        undo.undo()
        XCTAssertFalse(store.boards[0].cards.contains { $0.id == card.id })

        undo.redo()
        XCTAssertEqual(store.boards[0].cards.map(\.title), ["x"])
    }

    func testUndoIsPersistedToDisk() throws {
        let store = try makeStore()
        let undo = undoable(store)
        let board = try store.createBoard(name: "b")
        var card = try store.addCard(boardID: board.id, columnID: board.extraColumns[0].id, title: "before")
        card.title = "after"
        try store.updateCard(boardID: board.id, card: card)
        undo.undo()

        XCTAssertEqual(try makeStore().boards[0].cards[0].title, "before")
    }

    func testNothingIsRegisteredWithoutAnUndoManager() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "b")
        var card = try store.addCard(boardID: board.id, columnID: board.extraColumns[0].id, title: "before")
        card.title = "after"
        try store.updateCard(boardID: board.id, card: card)
        XCTAssertEqual(store.boards[0].cards[0].title, "after")

        // Attaching an undo manager only now proves nothing was queued while it was absent —
        // a fresh UndoManager with nothing registered can't undo.
        let undo = undoable(store)
        XCTAssertFalse(undo.canUndo)
    }

    func testMoveCardWithinAColumnUndoRestoresTheOldOrderAndRedoReapplies() throws {
        let store = try makeStore()
        let undo = undoable(store)
        let board = try store.createBoard(name: "b")
        let todo = board.extraColumns[0].id
        for title in ["a", "b", "c"] { _ = try store.addCard(boardID: board.id, columnID: todo, title: title) }
        let c = store.boards[0].cards[2]

        try store.moveCard(id: c.id, boardID: board.id, toColumn: todo, index: 0)
        XCTAssertEqual(store.cards(in: store.boards[0], column: todo).map(\.title), ["c", "a", "b"])

        undo.undo()
        XCTAssertEqual(store.cards(in: store.boards[0], column: todo).map(\.title), ["a", "b", "c"])

        undo.redo()
        XCTAssertEqual(store.cards(in: store.boards[0], column: todo).map(\.title), ["c", "a", "b"])
    }

    // MARK: - attachments

    func testAddAttachmentStoresTheFileAndTheName() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "b")
        let card = try store.addCard(boardID: board.id, columnID: board.extraColumns[0].id, title: "c")
        let name = try store.addAttachment(boardID: board.id, cardID: card.id, data: Data([1, 2]), ext: "png")

        XCTAssertEqual(store.boards[0].cards[0].attachments, [name])
        let url = store.attachmentURL(cardID: card.id, name: name)
        XCTAssertEqual(url, tempDir.appendingPathComponent("Attachments/\(card.id.uuidString)/\(name)"))
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2]))
        XCTAssertEqual(try makeStore().boards[0].cards[0].attachments, [name])
    }

    func testRemoveAttachmentDeletesTheFileAndUndoBringsItBack() throws {
        let store = try makeStore()
        let undo = undoable(store)
        let board = try store.createBoard(name: "b")
        let card = try store.addCard(boardID: board.id, columnID: board.extraColumns[0].id, title: "c")
        let name = try store.addAttachment(boardID: board.id, cardID: card.id, data: Data([7]), ext: "png")
        let url = store.attachmentURL(cardID: card.id, name: name)

        try store.removeAttachment(boardID: board.id, cardID: card.id, name: name)
        XCTAssertNil(store.boards[0].cards[0].attachments)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        undo.undo()
        XCTAssertEqual(store.boards[0].cards[0].attachments, [name])
        XCTAssertEqual(try Data(contentsOf: url), Data([7]))
    }

    func testDeleteCardRemovesItsFilesAndUndoRestoresThem() throws {
        let store = try makeStore()
        let undo = undoable(store)
        let board = try store.createBoard(name: "b")
        let card = try store.addCard(boardID: board.id, columnID: board.extraColumns[0].id, title: "c")
        let name = try store.addAttachment(boardID: board.id, cardID: card.id, data: Data([5]), ext: "png")
        let url = store.attachmentURL(cardID: card.id, name: name)

        try store.deleteCard(boardID: board.id, cardID: card.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        undo.undo()
        XCTAssertEqual(store.boards[0].cards[0].attachments, [name])
        XCTAssertEqual(try Data(contentsOf: url), Data([5]))
    }

    func testAddCardWithAnImageUndoesAsOneStep() throws {
        let store = try makeStore()
        let undo = undoable(store)
        let board = try store.createBoard(name: "b")
        let card = try store.addCard(boardID: board.id, columnID: board.extraColumns[0].id,
                                     title: "shot", image: Data([9]), ext: "png")

        let name = try XCTUnwrap(store.boards[0].cards.first?.attachments?.first)
        let url = store.attachmentURL(cardID: card.id, name: name)
        XCTAssertEqual(try Data(contentsOf: url), Data([9]))

        // One undo, not two: the card and the file it was dropped as are one user action.
        undo.undo()
        XCTAssertTrue(store.boards[0].cards.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        undo.redo()
        XCTAssertEqual(store.boards[0].cards.map(\.title), ["shot"])
        XCTAssertEqual(store.boards[0].cards[0].attachments, [name])
        XCTAssertEqual(try Data(contentsOf: url), Data([9]))
    }

    func testDeleteBoardRemovesEveryCardsFiles() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "b")
        let card = try store.addCard(boardID: board.id, columnID: board.extraColumns[0].id, title: "c")
        _ = try store.addAttachment(boardID: board.id, cardID: card.id, data: Data([5]), ext: "png")
        try store.deleteBoard(id: board.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("Attachments/\(card.id.uuidString)").path))
    }

    func testStoreWrittenBeforeAttachmentsStillDecodes() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "b")
        _ = try store.addCard(boardID: board.id, columnID: board.extraColumns[0].id, title: "c")
        let boardURL = tempDir.appendingPathComponent("\(board.id.uuidString).json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: boardURL)) as? [String: Any])
        var cards = try XCTUnwrap(json["cards"] as? [[String: Any]])
        cards[0].removeValue(forKey: "attachments")
        json["cards"] = cards
        try JSONSerialization.data(withJSONObject: json).write(to: boardURL)
        XCTAssertNil(try makeStore().boards[0].cards[0].attachments)
    }

    // MARK: - archive

    func testArchivedCardIsHiddenUnlessShowArchived() {
        var card = Card(title: "a", columnID: UUID())
        card.archived = Date()
        XCTAssertFalse(card.matches(labels: []))
        XCTAssertTrue(card.matches(labels: [], showArchived: true))
    }

    func testSetArchivedStampsDatePersistsAndUndoes() throws {
        let store = try makeStore()
        let undo = UndoManager(); undo.groupsByEvent = false
        store.undoManager = undo
        let board = try store.createBoard(name: "B")
        let col = board.extraColumns[0].id
        let a = try store.addCard(boardID: board.id, columnID: col, title: "a")
        let b = try store.addCard(boardID: board.id, columnID: col, title: "b")
        let now = Date(timeIntervalSince1970: 1_000)
        try store.setArchived(boardID: board.id, cardIDs: [a.id, b.id], true, now: now)
        XCTAssertEqual(try makeStore().boards[0].cards.map(\.archived), [now, now])
        undo.undo()
        XCTAssertEqual(store.boards[0].cards.map(\.archived), [nil, nil])
    }

    func testSetArchivedKeepsOriginalDateOfAlreadyArchivedCard() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "B")
        let a = try store.addCard(boardID: board.id, columnID: board.extraColumns[0].id, title: "a")
        let first = Date(timeIntervalSince1970: 1)
        try store.setArchived(boardID: board.id, cardIDs: [a.id], true, now: first)
        try store.setArchived(boardID: board.id, cardIDs: [a.id], true, now: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(store.boards[0].cards[0].archived, first)
    }

    func testArchivedCardsDoNotRemind() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "B")
        var a = try store.addCard(boardID: board.id, columnID: board.extraColumns[0].id, title: "a")
        a.due = Date().addingTimeInterval(3600)
        try store.updateCard(boardID: board.id, card: a)
        try store.setArchived(boardID: board.id, cardIDs: [a.id], true)
        XCTAssertTrue(store.pendingDueReminders(now: Date()).isEmpty)
    }

    func testGroupedMutationsUndoAsOneStep() throws {
        let store = try makeStore()
        let undo = UndoManager(); undo.groupsByEvent = false
        store.undoManager = undo
        let board = try store.createBoard(name: "B")
        let col = board.extraColumns[0].id
        let ids = try (0..<3).map { try store.addCard(boardID: board.id, columnID: col, title: "\($0)").id }
        try store.grouped { for id in ids { try store.deleteCard(boardID: board.id, cardID: id) } }
        XCTAssertTrue(store.boards[0].cards.isEmpty)
        undo.undo()
        XCTAssertEqual(store.boards[0].cards.count, 3)
    }

    func testClipboardTextIsTitleThenNotes() {
        XCTAssertEqual(Card(title: "T", body: "  n1\nn2 ", columnID: UUID()).clipboardText, "T\n\nn1\nn2")
        XCTAssertEqual(Card(title: "T", body: "   ", columnID: UUID()).clipboardText, "T")
        XCTAssertEqual(Card(title: "T", columnID: UUID()).clipboardText, "T")
    }
}
