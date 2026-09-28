import XCTest
@testable import MeatPadKit

@MainActor
final class ColumnIconSuggesterTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    // MARK: - Keywords

    func testKeywordsMatchWholeWordsCaseInsensitively() {
        XCTAssertEqual(ColumnIconSuggester.emoji(forName: "In Progress"), "🚧")
        XCTAssertEqual(ColumnIconSuggester.emoji(forName: "DONE"), "✅")
        XCTAssertEqual(ColumnIconSuggester.emoji(forName: "Code Review"), "👀")
        XCTAssertEqual(ColumnIconSuggester.emoji(forName: "Bugs & issues"), "🐛")
    }

    func testToDoInAnySpellingIsTodo() {
        for name in ["Todo", "To Do", "To-Do", "TO DO"] {
            XCTAssertEqual(ColumnIconSuggester.emoji(forName: name), "📋", name)
        }
    }

    /// "Blocked review" is blocked first — the rule order is the priority.
    func testTheMoreSpecificRuleWins() {
        XCTAssertEqual(ColumnIconSuggester.emoji(forName: "Blocked review"), "🚫")
    }

    /// A substring is not a word: "Doneness" and "Undone" are not the Done column.
    func testASubstringIsNotAMatch() {
        XCTAssertNil(ColumnIconSuggester.emoji(forName: "Doneness"))
        XCTAssertNil(ColumnIconSuggester.emoji(forName: "Undone"))
        XCTAssertNil(ColumnIconSuggester.emoji(forName: "Sprint 12"))
        XCTAssertNil(ColumnIconSuggester.emoji(forName: ""))
    }

    // MARK: - BoardStore.suggestedEmoji

    func testAColumnWithALookNeedsNoSuggestion() throws {
        let store = try BoardStore(rootURL: tempDir)
        XCTAssertNil(store.suggestedEmoji(for: BoardColumn(name: "Done", emoji: "🎉")))
        XCTAssertNil(store.suggestedEmoji(for: BoardColumn(name: "Done", image: "x.png")))
    }

    /// Another board's column of the same name (case and diacritics aside) lends its emoji,
    /// ahead of the keyword guess.
    func testTheSameNamedColumnOnAnotherBoardLendsItsEmoji() throws {
        let store = try BoardStore(rootURL: tempDir)
        let a = try store.createBoard(name: "a")
        let b = try store.createBoard(name: "b")
        try store.addExtraColumn(boardID: a.id, name: "Ideas")
        let ideas = store.boards[0].extraColumns.last!
        try store.setColumnIcon(id: ideas.id, emoji: "🌱", boardID: a.id)
        try store.addExtraColumn(boardID: b.id, name: "  ideas ")

        let bare = store.boards[1].extraColumns.last!
        XCTAssertEqual(store.suggestedEmoji(for: bare), "🌱")
    }

    func testTheMostCommonBorrowedEmojiWins() throws {
        let store = try BoardStore(rootURL: tempDir)
        let boards = try (0..<4).map { try store.createBoard(name: "b\($0)") }
        for (i, emoji) in ["🌱", "🌿", "🌿"].enumerated() {
            try store.addExtraColumn(boardID: boards[i].id, name: "Sprint")
            let column = store.boards[i].extraColumns.last!
            try store.setColumnIcon(id: column.id, emoji: emoji, boardID: boards[i].id)
        }
        try store.addExtraColumn(boardID: boards[3].id, name: "Sprint")

        XCTAssertEqual(store.suggestedEmoji(for: store.boards[3].extraColumns.last!), "🌿")
    }

    /// No other board has it: the keyword rule answers, and a name it doesn't know gets nothing.
    func testFallsBackToTheKeywordThenToNothing() throws {
        let store = try BoardStore(rootURL: tempDir)
        XCTAssertEqual(store.suggestedEmoji(for: BoardColumn(name: "Blocked")), "🚫")
        XCTAssertNil(store.suggestedEmoji(for: BoardColumn(name: "Sprint 12")))
    }

    /// A suggestion is never written: asking leaves the board file exactly as it was.
    func testSuggestingChangesNothing() throws {
        let store = try BoardStore(rootURL: tempDir)
        let board = try store.createBoard(name: "a")
        try store.addExtraColumn(boardID: board.id, name: "Done")
        let column = store.boards[0].extraColumns.last!
        let before = store.boards

        XCTAssertEqual(store.suggestedEmoji(for: column), "✅")
        XCTAssertEqual(store.boards, before)
        XCTAssertNil(store.boards[0].extraColumns.last!.emoji)
    }
}
