import XCTest
@testable import MeatPadKit

@MainActor
final class DirectoryWatcherTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    // Wiring test: FSEvents is a real OS facility, not a mock — this creates a file
    // under a temp root and waits (generous timeout) for the debounced callback to
    // fire. Can be flaky under heavy CI load; see report for observed local stability.
    func testOnChangeFiresAfterFileCreatedUnderRoot() throws {
        let expectation = expectation(description: "onChange fired")
        var changedPaths: [String] = []
        let watcher = DirectoryWatcher(root: tempDir, debounce: 0.3) { paths in
            changedPaths = paths
            expectation.fulfill()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [tempDir] in
            try? Data("hello".utf8).write(to: tempDir!.appendingPathComponent("new.txt"))
        }

        wait(for: [expectation], timeout: 3)
        XCTAssertTrue(changedPaths.contains { $0.hasSuffix("/new.txt") })
        watcher.stop()
    }

    func testIgnoredPathsDoNotFireButOthersStillDo() throws {
        let git = tempDir.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        let fired = expectation(description: "onChange fired")
        var changedPaths: [String] = []
        let watcher = DirectoryWatcher(root: tempDir, debounce: 0.3, ignoring: [".git"]) { paths in
            changedPaths = paths
            fired.fulfill()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [tempDir, git] in
            try? Data("x".utf8).write(to: git.appendingPathComponent("index"))
            try? Data("x".utf8).write(to: tempDir!.appendingPathComponent("real.txt"))
        }

        wait(for: [fired], timeout: 3)
        XCTAssertTrue(changedPaths.contains { $0.hasSuffix("/real.txt") })
        XCTAssertFalse(changedPaths.contains { $0.contains("/.git/") })
        watcher.stop()
    }

    func testStopIsIdempotent() throws {
        let watcher = DirectoryWatcher(root: tempDir) { _ in }
        watcher.stop()
        watcher.stop() // must not crash
    }
}
