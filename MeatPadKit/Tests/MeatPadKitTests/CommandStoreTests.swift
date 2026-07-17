import XCTest
@testable import MeatPadKit

@MainActor
final class CommandStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    private func makeStore() -> CommandStore {
        CommandStore(directory: tempDir)
    }

    private func makeCommand(
        name: String = "My Command",
        script: String = "echo hi",
        input: CommandInput = .none,
        output: CommandOutputMode = .outputPanel,
        languageIDs: [String] = []
    ) -> SavedCommand {
        SavedCommand(name: name, script: script, input: input, output: output, languageIDs: languageIDs)
    }

    // MARK: - init / empty dir

    func testEmptyDirLoadsNoCommands() {
        let store = makeStore()
        XCTAssertEqual(store.commands, [])
    }

    func testInitCreatesDirectoryOnDemand() {
        _ = makeStore()
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    // MARK: - add

    func testAddPersistsFileAndAppearsInCommands() throws {
        let store = makeStore()
        let command = makeCommand()

        try store.add(command)

        let fileURL = tempDir.appendingPathComponent("\(command.id.uuidString).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(store.commands.contains(command))
    }

    func testAddingSameIDTwiceReplacesInPlaceInsteadOfAppending() throws {
        let store = makeStore()
        let command = makeCommand()

        try store.add(command)
        var changed = command
        changed.script = "echo changed"
        try store.add(changed)

        XCTAssertEqual(store.commands.count, 1)
        XCTAssertEqual(store.commands.first?.script, "echo changed")

        let contents = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(contents.filter { $0.pathExtension == "json" }.count, 1)
    }

    // MARK: - update

    func testUpdateRewritesFile() throws {
        let store = makeStore()
        var command = makeCommand()
        try store.add(command)

        command.script = "echo changed"
        try store.update(command)

        XCTAssertEqual(store.commands.first(where: { $0.id == command.id })?.script, "echo changed")

        let fileURL = tempDir.appendingPathComponent("\(command.id.uuidString).json")
        let reloaded = try JSONDecoder().decode(SavedCommand.self, from: Data(contentsOf: fileURL))
        XCTAssertEqual(reloaded.script, "echo changed")
    }

    func testUpdateUnknownIDThrowsNotFound() {
        let store = makeStore()
        let command = makeCommand(name: "Ghost")

        XCTAssertThrowsError(try store.update(command)) { error in
            XCTAssertEqual(error as? CommandStoreError, .notFound(command.id))
        }
    }

    // MARK: - delete

    func testDeleteRemovesFileAndFromCommands() throws {
        let store = makeStore()
        let command = makeCommand()
        try store.add(command)

        try store.delete(id: command.id)

        let fileURL = tempDir.appendingPathComponent("\(command.id.uuidString).json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(store.commands.contains(where: { $0.id == command.id }))
    }

    func testDeleteUnknownIDDoesNotThrow() {
        let store = makeStore()
        XCTAssertNoThrow(try store.delete(id: UUID()))
    }

    // MARK: - persistence (reload)

    func testReloadViaNewInstanceSeesPersistedCommand() throws {
        let store1 = makeStore()
        let command = makeCommand(name: "Persisted")
        try store1.add(command)

        let store2 = makeStore()

        XCTAssertEqual(store2.commands.count, 1)
        XCTAssertEqual(store2.commands.first?.id, command.id)
    }

    // MARK: - corrupt JSON self-heal

    func testCorruptCommandFileIsSkippedWithoutCrashingLoad() throws {
        let store1 = makeStore()
        let good = makeCommand(name: "Good")
        try store1.add(good)

        try Data("not json {{{".utf8).write(to: tempDir.appendingPathComponent("\(UUID().uuidString).json"))

        let store2 = makeStore()
        XCTAssertEqual(store2.commands.count, 1)
        XCTAssertEqual(store2.commands.first?.id, good.id)
    }

    // MARK: - commands(forLanguageID:)

    func testCommandsForLanguageIDFiltersScopeAndIncludesAllLanguage() throws {
        let store = makeStore()
        let swiftOnly = makeCommand(name: "Swift Only", languageIDs: ["swift"])
        let pythonOnly = makeCommand(name: "Python Only", languageIDs: ["python"])
        let universal = makeCommand(name: "Universal", languageIDs: [])
        try store.add(swiftOnly)
        try store.add(pythonOnly)
        try store.add(universal)

        let result = store.commands(forLanguageID: "swift")

        XCTAssertTrue(result.contains(swiftOnly))
        XCTAssertTrue(result.contains(universal))
        XCTAssertFalse(result.contains(pythonOnly))
    }

    func testCommandsForNilLanguageIDReturnsOnlyAllLanguageCommands() throws {
        let store = makeStore()
        let swiftOnly = makeCommand(name: "Swift Only", languageIDs: ["swift"])
        let universal = makeCommand(name: "Universal", languageIDs: [])
        try store.add(swiftOnly)
        try store.add(universal)

        let result = store.commands(forLanguageID: nil)

        XCTAssertTrue(result.allSatisfy { $0.languageIDs.isEmpty })
        XCTAssertTrue(result.contains(universal))
    }
}
