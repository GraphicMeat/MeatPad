import XCTest
@testable import MeatPadKit

final class TerminalLaunchTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/work/proj", isDirectory: true)

    private func env(_ spec: TerminalLaunchSpec) -> [String: String] {
        var result: [String: String] = [:]
        for entry in spec.environment {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            result[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        return result
    }

    // MARK: - executable

    func testUserShellWinsOverProcessShell() {
        let spec = TerminalLaunch.spec(root: root, userEnvironment: ["SHELL": "/opt/homebrew/bin/fish"], processEnvironment: ["SHELL": "/bin/bash"])
        XCTAssertEqual(spec.executable, "/opt/homebrew/bin/fish")
    }

    func testProcessShellIsTheFallback() {
        let spec = TerminalLaunch.spec(root: root, userEnvironment: [:], processEnvironment: ["SHELL": "/bin/bash"])
        XCTAssertEqual(spec.executable, "/bin/bash")
    }

    func testRelativeOrMissingShellFallsBackToZsh() {
        XCTAssertEqual(TerminalLaunch.spec(root: root, userEnvironment: ["SHELL": "fish"], processEnvironment: [:]).executable, "/bin/zsh")
        XCTAssertEqual(TerminalLaunch.spec(root: root, userEnvironment: ["SHELL": ""], processEnvironment: [:]).executable, "/bin/zsh")
        XCTAssertEqual(TerminalLaunch.spec(root: root, userEnvironment: [:], processEnvironment: [:]).executable, "/bin/zsh")
    }

    func testLoginShellFlagAndWorkingDirectory() {
        let spec = TerminalLaunch.spec(root: root, userEnvironment: [:], processEnvironment: [:])
        XCTAssertEqual(spec.args, ["-l"])
        XCTAssertEqual(spec.currentDirectory, "/work/proj")
    }

    // MARK: - environment

    func testTerminalVariablesAreSetAndUserPathIsKept() {
        let spec = TerminalLaunch.spec(root: root, userEnvironment: ["PATH": "/opt/homebrew/bin:/usr/bin", "HOME": "/Users/me"], processEnvironment: [:])
        let e = env(spec)
        XCTAssertEqual(e["TERM"], "xterm-256color")
        XCTAssertEqual(e["COLORTERM"], "truecolor")
        XCTAssertEqual(e["TERM_PROGRAM"], "MeatPad")
        XCTAssertEqual(e["PATH"], "/opt/homebrew/bin:/usr/bin")
        XCTAssertEqual(e["HOME"], "/Users/me")
    }

    func testUserLangIsPreservedAndDefaultedWhenMissing() {
        XCTAssertEqual(env(TerminalLaunch.spec(root: root, userEnvironment: ["LANG": "lt_LT.UTF-8"], processEnvironment: [:]))["LANG"], "lt_LT.UTF-8")
        XCTAssertEqual(env(TerminalLaunch.spec(root: root, userEnvironment: [:], processEnvironment: [:]))["LANG"], "en_US.UTF-8")
    }

    func testUserTermIsOverriddenAndNoKeyAppearsTwice() {
        let spec = TerminalLaunch.spec(root: root, userEnvironment: ["TERM": "dumb", "COLORTERM": "no"], processEnvironment: [:])
        let keys = spec.environment.map { $0.split(separator: "=", maxSplits: 1)[0] }
        XCTAssertEqual(keys.count, Set(keys).count, "duplicate keys: \(keys)")
        XCTAssertEqual(env(spec)["TERM"], "xterm-256color")
        XCTAssertEqual(env(spec)["COLORTERM"], "truecolor")
    }

    func testEnvironmentIsSortedForStableProcessImages() {
        let spec = TerminalLaunch.spec(root: root, userEnvironment: ["ZZ": "1", "AA": "2"], processEnvironment: [:])
        XCTAssertEqual(spec.environment, spec.environment.sorted())
    }

    // MARK: - cd command

    func testChangeDirectoryCommandQuotesAndEndsWithNewline() {
        let url = URL(fileURLWithPath: "/work/my proj/sub dir", isDirectory: true)
        XCTAssertEqual(TerminalLaunch.changeDirectoryCommand(to: url), "cd '/work/my proj/sub dir'\n")
    }

    func testChangeDirectoryCommandEscapesSingleQuotesAndKeepsUnicode() {
        let url = URL(fileURLWithPath: "/work/it's/žolė", isDirectory: true)
        XCTAssertEqual(TerminalLaunch.changeDirectoryCommand(to: url), "cd '/work/it'\\''s/žolė'\n")
    }
}
