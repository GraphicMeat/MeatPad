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
        let watcher = DirectoryWatcher(root: tempDir, debounce: 0.3) {
            expectation.fulfill()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [tempDir] in
            try? Data("hello".utf8).write(to: tempDir!.appendingPathComponent("new.txt"))
        }

        wait(for: [expectation], timeout: 3)
        watcher.stop()
    }

    func testStopIsIdempotent() throws {
        let watcher = DirectoryWatcher(root: tempDir) {}
        watcher.stop()
        watcher.stop() // must not crash
    }
}
