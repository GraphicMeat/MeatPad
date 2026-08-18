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

    /// v1 session.json files (written before openProjects existed) have no such key —
    /// they must still decode, defaulting to an empty array, not fail to load entirely.
    func testV1JSONWithoutOpenProjectsKeyDecodesWithEmptyProjects() throws {
        let noteID = UUID()
        let v1JSON = """
        {"openNoteIDs":["\(noteID.uuidString)"],"browserOpen":true}
        """
        try Data(v1JSON.utf8).write(to: url)

        let loaded = SessionState.load(from: url)

        XCTAssertEqual(loaded, SessionState(openNoteIDs: [noteID], browserOpen: true, openProjects: []))
    }

    func testOpenProjectsRoundTrip() throws {
        let projects = [
            ProjectSession(root: "/tmp/one", openTabs: ["/tmp/one/a.txt", "/tmp/one/b.txt"], selectedTab: "/tmp/one/b.txt"),
            ProjectSession(root: "/tmp/two", openTabs: [], selectedTab: nil)
        ]
        let state = SessionState(openNoteIDs: [UUID()], browserOpen: false, openProjects: projects)

        try state.save(to: url)

        XCTAssertEqual(SessionState.load(from: url), state)
    }

    // MARK: - boardsOpen

    func testDecodesLegacySessionWithoutBoardsOpen() throws {
        let json = Data(#"{"openNoteIDs":[],"browserOpen":true,"openProjects":[]}"#.utf8)
        let state = try JSONDecoder().decode(SessionState.self, from: json)
        XCTAssertFalse(state.boardsOpen)
        XCTAssertTrue(state.browserOpen)
    }

    func testBoardsOpenRoundTrips() throws {
        let state = SessionState(openNoteIDs: [], browserOpen: false, openProjects: [], boardsOpen: true)
        let decoded = try JSONDecoder().decode(SessionState.self, from: JSONEncoder().encode(state))
        XCTAssertTrue(decoded.boardsOpen)
    }
}
