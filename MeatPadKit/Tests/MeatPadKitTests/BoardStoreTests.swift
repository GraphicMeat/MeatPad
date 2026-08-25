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

    // MARK: - cards

    private func makeBoard(_ store: BoardStore) throws -> Board {
        try store.createBoard(name: "project1")
    }

    func testAddCardLandsInColumnAndPersists() throws {
        let store = try makeStore()
        let board = try makeBoard(store)
        let todo = store.globalColumns[0]
        let card = try store.addCard(boardID: board.id, columnID: todo.id, title: "ship it")

        XCTAssertEqual(card.title, "ship it")
        XCTAssertEqual(card.columnID, todo.id)
        XCTAssertEqual(store.cards(in: store.boards[0], column: todo.id).map(\.id), [card.id])
        XCTAssertEqual(try makeStore().boards[0].cards.map(\.title), ["ship it"])
    }

    func testAddCardRejectsEmptyTitleAndUnknownColumn() throws {
        let store = try makeStore()
        let board = try makeBoard(store)
        XCTAssertThrowsError(try store.addCard(boardID: board.id, columnID: store.globalColumns[0].id, title: " ")) {
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
        var card = try store.addCard(boardID: board.id, columnID: store.globalColumns[0].id, title: "a")
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
        let card = try store.addCard(boardID: board.id, columnID: store.globalColumns[0].id, title: "a")
        try store.deleteCard(boardID: board.id, cardID: card.id)

        XCTAssertTrue(store.boards[0].cards.isEmpty)
        XCTAssertTrue(try makeStore().boards[0].cards.isEmpty)
    }

    func testMoveCardChangesColumnAndPosition() throws {
        let store = try makeStore()
        let board = try makeBoard(store)
        let todo = store.globalColumns[0].id
        let doing = store.globalColumns[1].id
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
        let todo = store.globalColumns[0].id
        let a = try store.addCard(boardID: board.id, columnID: todo, title: "a")
        _ = try store.addCard(boardID: board.id, columnID: todo, title: "b")
        _ = try store.addCard(boardID: board.id, columnID: todo, title: "c")

        try store.moveCard(id: a.id, boardID: board.id, toColumn: todo, index: 2)
        XCTAssertEqual(store.cards(in: store.boards[0], column: todo).map(\.title), ["b", "c", "a"])
    }

    func testMoveCardRejectsUnknownColumnAndCard() throws {
        let store = try makeStore()
        let board = try makeBoard(store)
        let card = try store.addCard(boardID: board.id, columnID: store.globalColumns[0].id, title: "a")
        let unknownColumn = UUID()
        XCTAssertThrowsError(try store.moveCard(id: card.id, boardID: board.id, toColumn: unknownColumn, index: 0)) {
            XCTAssertEqual($0 as? BoardStoreError, .columnNotFound(unknownColumn))
        }
        let unknownCard = UUID()
        XCTAssertThrowsError(try store.moveCard(id: unknownCard, boardID: board.id, toColumn: store.globalColumns[1].id, index: 0)) {
            XCTAssertEqual($0 as? BoardStoreError, .cardNotFound(unknownCard))
        }
    }

    // MARK: - column editing

    func testAddGlobalColumnAppearsOnEveryBoardAndPersists() throws {
        let store = try makeStore()
        _ = try store.createBoard(name: "a")
        _ = try store.createBoard(name: "b")
        try store.addGlobalColumn(name: "Review")

        XCTAssertEqual(store.columns(for: store.boards[0]).map(\.name).last, "Review")
        XCTAssertEqual(store.columns(for: store.boards[1]).map(\.name).last, "Review")
        XCTAssertEqual(try makeStore().globalColumns.map(\.name), ["Todo", "In Progress", "Done", "Review"])
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
        let todo = store.globalColumns[0].id
        let card = try store.addCard(boardID: board.id, columnID: todo, title: "x")
        try store.renameColumn(id: todo, to: "Backlog", boardID: nil)

        XCTAssertEqual(store.globalColumns[0].name, "Backlog")
        XCTAssertEqual(store.cards(in: store.boards[0], column: todo).map(\.id), [card.id])
        XCTAssertEqual(try makeStore().globalColumns[0].name, "Backlog")
    }

    func testSetColumnDoneFlagsAndPersists() throws {
        let store = try makeStore()
        let todo = store.globalColumns[0].id
        try store.setColumnDone(id: todo, true, boardID: nil)

        XCTAssertTrue(store.globalColumns[0].isDone)
        XCTAssertTrue(try makeStore().globalColumns[0].isDone)
    }

    func testDeleteColumnReassignsItsCardsToFirstGlobalColumn() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "a")
        let todo = store.globalColumns[0].id
        let doing = store.globalColumns[1].id
        let card = try store.addCard(boardID: board.id, columnID: doing, title: "x")
        try store.deleteColumn(id: doing, boardID: nil)

        XCTAssertEqual(store.globalColumns.map(\.name), ["Todo", "Done"])
        XCTAssertEqual(store.cards(in: store.boards[0], column: todo).map(\.id), [card.id])
        XCTAssertEqual(try makeStore().boards[0].cards[0].columnID, todo)
    }

    func testDeleteExtraColumnReassignsToFirstGlobalColumn() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "a")
        try store.addExtraColumn(boardID: board.id, name: "Blocked")
        let blocked = store.boards[0].extraColumns[0].id
        let card = try store.addCard(boardID: board.id, columnID: blocked, title: "x")
        try store.deleteColumn(id: blocked, boardID: board.id)

        XCTAssertTrue(store.boards[0].extraColumns.isEmpty)
        XCTAssertEqual(store.boards[0].cards.first(where: { $0.id == card.id })?.columnID, store.globalColumns[0].id)
    }

    func testCannotDeleteLastGlobalColumn() throws {
        let store = try makeStore()
        try store.deleteColumn(id: store.globalColumns[2].id, boardID: nil)
        try store.deleteColumn(id: store.globalColumns[1].id, boardID: nil)

        XCTAssertThrowsError(try store.deleteColumn(id: store.globalColumns[0].id, boardID: nil)) {
            XCTAssertEqual($0 as? BoardStoreError, .lastColumn)
        }
    }

    // MARK: - note link + due reminders

    func testCardForNoteFindsAndMisses() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "a")
        var card = try store.addCard(boardID: board.id, columnID: store.globalColumns[0].id, title: "x")
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
        let todo = store.globalColumns[0].id
        let done = store.globalColumns[2].id
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
            var card = try store.addCard(boardID: board.id, columnID: store.globalColumns[0].id, title: board.name)
            card.due = now.addingTimeInterval(60)
            try store.updateCard(boardID: board.id, card: card)
        }

        XCTAssertEqual(store.pendingDueReminders(now: now).map(\.title).sorted(), ["a", "b"])
    }

    // MARK: - column emoji

    func testSeedsDefaultColumnEmoji() throws {
        let store = try makeStore()
        XCTAssertEqual(store.globalColumns.map(\.emoji), ["📋", "🚧", "✅"])
    }

    func testAssignsEmojiToAPreEmojiStoreOnce() throws {
        let store = try makeStore()
        let index = tempDir.appendingPathComponent("boards.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any])
        var columns = try XCTUnwrap(json["globalColumns"] as? [[String: Any]])
        for i in columns.indices { columns[i].removeValue(forKey: "emoji") }
        json["globalColumns"] = columns
        try JSONSerialization.data(withJSONObject: json).write(to: index)
        _ = store

        let healed = try makeStore()
        XCTAssertEqual(healed.globalColumns.map(\.emoji), ["📋", "🚧", "✅"])
        // Second load must not re-run the heal over a user's own choices.
        try healed.renameColumn(id: healed.globalColumns[0].id, to: "Backlog", boardID: nil)
        XCTAssertEqual(try makeStore().globalColumns.map(\.emoji), ["📋", "🚧", "✅"])
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
        var card = try store.addCard(boardID: board.id, columnID: store.globalColumns[0].id, title: "c")
        card.labelIDs = [label.id]
        try store.updateCard(boardID: board.id, card: card)
        XCTAssertEqual(try makeStore().boards[0].cards[0].labelIDs, [label.id])
    }

    func testDeletingALabelStripsItFromEveryCard() throws {
        let store = try makeStore()
        let keep = try store.createLabel(name: "Keep")
        let drop = try store.createLabel(name: "Drop")
        let board = try store.createBoard(name: "b")
        var card = try store.addCard(boardID: board.id, columnID: store.globalColumns[0].id, title: "c")
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
        var card = try store.addCard(boardID: board.id, columnID: store.globalColumns[0].id, title: "c")
        card.color = CardLabel.palette[4]
        try store.updateCard(boardID: board.id, card: card)

        XCTAssertEqual(try makeStore().boards[0].cards[0].color, CardLabel.palette[4])
    }

    func testClearingCardColorPersistsAsNil() throws {
        let store = try makeStore()
        let board = try store.createBoard(name: "b")
        var card = try store.addCard(boardID: board.id, columnID: store.globalColumns[0].id, title: "c")
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
        _ = try store.addCard(boardID: board.id, columnID: store.globalColumns[0].id, title: "c")

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
}
