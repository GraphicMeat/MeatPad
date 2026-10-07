import XCTest
@testable import MeatPadKit

final class GitMenuConfigTests: XCTestCase {

    /// `"git status"` (run), `"|"` (divider), `"git commit -m \"\" ✎"` (type only).
    private func layout(_ config: GitMenuConfig) -> [String] {
        config.items.map { $0.isDivider ? "|" : ($0.runs ? $0.command : $0.command + " ✎") }
    }

    func testDefaultsAreThePopularCommandsInOrder() {
        XCTAssertEqual(layout(.defaults), [
            "git status", "git fetch", "git pull", "git push",
            "|",
            "git add -A", "git commit -m \"\" ✎", "git commit --amend --no-edit ✎",
            "|",
            "git log --oneline -20", "git diff", "git stash", "git stash pop", "git switch -c  ✎",
        ])
    }

    func testDefaultSwitchKeepsItsTrailingSpace() {
        XCTAssertEqual(GitMenuConfig.defaults.items.last?.command, "git switch -c ")
    }

    func testEveryItemGetsItsOwnID() {
        let ids = GitMenuConfig.defaults.items.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testMissingOrUnreadableDataIsTheDefaults() {
        XCTAssertEqual(GitMenuConfig.decode(nil), .defaults)
        XCTAssertEqual(GitMenuConfig.decode(Data("not json".utf8)), .defaults)
        XCTAssertEqual(GitMenuConfig.decode(Data("[1,2]".utf8)), .defaults)
        XCTAssertEqual(GitMenuConfig.decode(Data(#"{"other":1}"#.utf8)), .defaults)
        XCTAssertEqual(GitMenuConfig.decode(Data(#"{"items":"nope"}"#.utf8)), .defaults)
    }

    func testAnEmptyListStaysEmpty() {
        XCTAssertEqual(GitMenuConfig.decode(Data(#"{"items":[]}"#.utf8)).items, [])
    }

    func testRoundTripKeepsCommandsModesAndDividers() throws {
        let original = GitMenuConfig(items: [
            .command("git status", runs: true),
            .divider(),
            .command("git commit -m \"\"", runs: false),
            .command("git switch -c ", runs: false),
        ])
        let decoded = GitMenuConfig.decode(try original.encoded())
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(layout(decoded), ["git status", "|", "git commit -m \"\" ✎", "git switch -c  ✎"])
    }

    func testIDsAreNotPersisted() throws {
        let json = String(decoding: try GitMenuConfig.defaults.encoded(), as: UTF8.self)
        XCTAssertFalse(json.contains("\"id\""), json)
    }

    func testDecodesTheHandWrittenShape() {
        let json = #"{"items":[{"command":"git status","run":true},{"divider":true},{"command":"git commit -m \"\"","run":false}]}"#
        XCTAssertEqual(layout(GitMenuConfig.decode(Data(json.utf8))), ["git status", "|", "git commit -m \"\" ✎"])
    }

    func testMalformedEntriesAreSkipped() {
        let json = #"{"items":[5,"x",{"run":true},{"divider":false},{"command":"git diff","run":true},{"command":7}]}"#
        XCTAssertEqual(layout(GitMenuConfig.decode(Data(json.utf8))), ["git diff"])
    }

    func testACommandWithoutARunFlagIsTypedNotRun() {
        let json = #"{"items":[{"command":"git push --force"}]}"#
        XCTAssertEqual(layout(GitMenuConfig.decode(Data(json.utf8))), ["git push --force ✎"])
    }
}

final class GitMenuInputTests: XCTestCase {

    func testARunCommandClearsTheLineAndPressesReturn() {
        XCTAssertEqual(GitMenuInput.keystrokes(for: "git status", runs: true, applicationCursor: false),
                       "\u{15}git status\r")
    }

    func testATypedCommandEndingInDoubleQuotesLeavesTheCaretBetweenThem() {
        XCTAssertEqual(GitMenuInput.keystrokes(for: "git commit -m \"\"", runs: false, applicationCursor: false),
                       "\u{15}git commit -m \"\"\u{1B}[D")
    }

    /// zsh frameworks switch the terminal to application-cursor mode, where Left is ESC O D.
    func testApplicationCursorModeSendsTheOtherLeftArrow() {
        XCTAssertEqual(GitMenuInput.keystrokes(for: "git commit -m \"\"", runs: false, applicationCursor: true),
                       "\u{15}git commit -m \"\"\u{1B}OD")
    }

    func testSingleQuotesGetTheCaretToo() {
        XCTAssertEqual(GitMenuInput.keystrokes(for: "git commit -m ''", runs: false, applicationCursor: false),
                       "\u{15}git commit -m ''\u{1B}[D")
    }

    func testATypedCommandWithoutQuotesIsTypedAsIs() {
        XCTAssertEqual(GitMenuInput.keystrokes(for: "git commit --amend --no-edit", runs: false, applicationCursor: false),
                       "\u{15}git commit --amend --no-edit")
    }

    func testATrailingSpaceIsKeptVerbatim() {
        XCTAssertEqual(GitMenuInput.keystrokes(for: "git switch -c ", runs: false, applicationCursor: true),
                       "\u{15}git switch -c ")
    }

    /// Running is never "between the quotes": the command goes as written.
    func testARunCommandEndingInQuotesGetsNoArrow() {
        XCTAssertEqual(GitMenuInput.keystrokes(for: "git commit -m \"\"", runs: true, applicationCursor: false),
                       "\u{15}git commit -m \"\"\r")
    }
}
