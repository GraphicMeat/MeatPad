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

    // MARK: - trust/timeout/env migration (0.8)

    /// Verbatim shape of a command JSON written before the trust model existed —
    /// no `origin`/`trusted`/`timeoutSeconds`/`restrictedEnvironment` keys at all.
    /// Must decode without throwing and land on the grandfathered defaults.
    func testDecodingOldFormatJSONWithoutTrustFieldsAppliesDefaults() throws {
        let legacyID = UUID()
        let json = """
        {
          "id": "\(legacyID.uuidString)",
          "name": "Legacy Command",
          "script": "echo legacy",
          "input": "selection",
          "output": "insertAtCaret",
          "keyEquivalent": "cmd+shift+l",
          "languageIDs": ["swift", "python"]
        }
        """

        let decoded = try JSONDecoder().decode(SavedCommand.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.id, legacyID)
        XCTAssertEqual(decoded.name, "Legacy Command")
        XCTAssertEqual(decoded.script, "echo legacy")
        XCTAssertEqual(decoded.input, .selection)
        XCTAssertEqual(decoded.output, .insertAtCaret)
        XCTAssertEqual(decoded.keyEquivalent, "cmd+shift+l")
        XCTAssertEqual(decoded.languageIDs, ["swift", "python"])
        XCTAssertEqual(decoded.origin, .user)
        XCTAssertTrue(decoded.trusted)
        XCTAssertNil(decoded.timeoutSeconds)
        XCTAssertFalse(decoded.restrictedEnvironment)
    }

    func testCommandStoreLoadsOldFormatFileFromDiskWithDefaults() throws {
        let legacyID = UUID()
        let json = """
        {
          "id": "\(legacyID.uuidString)",
          "name": "Legacy On Disk",
          "script": "echo hi",
          "input": "none",
          "output": "outputPanel",
          "languageIDs": []
        }
        """
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: tempDir.appendingPathComponent("\(legacyID.uuidString).json"))

        let store = makeStore()

        XCTAssertEqual(store.commands.count, 1)
        XCTAssertEqual(store.commands.first?.trusted, true)
        XCTAssertEqual(store.commands.first?.origin, .user)
    }

    func testNewTrustFieldsRoundTripThroughEncodeDecode() throws {
        let command = SavedCommand(
            name: "Imported Cmd",
            script: "echo hi",
            input: .none,
            output: .outputPanel,
            origin: .imported(bundleName: "My.tmbundle", date: Date(timeIntervalSince1970: 1_700_000_000)),
            trusted: false,
            timeoutSeconds: 5,
            restrictedEnvironment: true
        )

        let data = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(SavedCommand.self, from: data)

        XCTAssertEqual(decoded, command)
    }

    func testDefaultInitAppliesUserTrustedFields() {
        let command = makeCommand()

        XCTAssertEqual(command.origin, .user)
        XCTAssertTrue(command.trusted)
        XCTAssertNil(command.timeoutSeconds)
        XCTAssertFalse(command.restrictedEnvironment)
    }

    /// Documents the on-disk shape of `CommandOrigin`: a flat tagged object, not the
    /// nested payload shape default enum-with-associated-values synthesis would produce.
    func testCommandOriginEncodesAsReadableTaggedObject() throws {
        let userData = try JSONEncoder().encode(CommandOrigin.user)
        XCTAssertEqual(String(decoding: userData, as: UTF8.self), #"{"type":"user"}"#)

        let importedData = try JSONEncoder().encode(CommandOrigin.imported(bundleName: "X.tmbundle", date: Date(timeIntervalSince1970: 0)))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: importedData) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "imported")
        XCTAssertEqual(obj["bundleName"] as? String, "X.tmbundle")
        XCTAssertNotNil(obj["date"])
    }

    func testCommandOriginRejectsUnknownTypeTag() {
        let json = #"{"type":"mystery"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(CommandOrigin.self, from: Data(json.utf8)))
    }

    /// CommandStore's on-disk format uses ISO8601 dates (matching NoteStore's convention),
    /// not the default epoch-Double encoding — otherwise `imported` origin dates would be
    /// unreadable/inconsistent with the rest of the app's persisted JSON.
    func testImportedOriginDateEncodesAsISO8601OnDiskAndRoundTrips() throws {
        let store1 = makeStore()
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        var command = makeCommand(name: "Imported")
        command.origin = .imported(bundleName: "My.tmbundle", date: originalDate)
        try store1.add(command)

        let fileURL = tempDir.appendingPathComponent("\(command.id.uuidString).json")
        let json = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(json.range(of: #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"#, options: .regularExpression) != nil, "expected an ISO8601 date string, got: \(json)")

        let store2 = makeStore()
        XCTAssertEqual(store2.commands.first?.origin, command.origin)
    }
}
