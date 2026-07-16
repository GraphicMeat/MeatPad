import XCTest
@testable import MeatPadKit

final class SessionStateTests: XCTestCase {

    private var tempDir: URL!
    private var url: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        url = tempDir.appendingPathComponent("session.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    func testRoundTripSaveAndLoad() throws {
        let state = SessionState(openNoteIDs: [UUID(), UUID()], browserOpen: true)

        try state.save(to: url)

        XCTAssertEqual(SessionState.load(from: url), state)
    }

    func testLoadFromMissingFileReturnsNil() {
        XCTAssertNil(SessionState.load(from: url))
    }

    func testLoadFromCorruptFileReturnsNil() throws {
        try Data("not json {{{".utf8).write(to: url)

        XCTAssertNil(SessionState.load(from: url))
    }

    func testSaveOverwritesExistingFile() throws {
        try SessionState(openNoteIDs: [UUID()], browserOpen: false).save(to: url)
        let second = SessionState(openNoteIDs: [], browserOpen: true)

        try second.save(to: url)

        XCTAssertEqual(SessionState.load(from: url), second)
    }
}
