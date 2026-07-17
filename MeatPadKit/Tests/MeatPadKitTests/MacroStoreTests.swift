import XCTest
@testable import MeatPadKit

@MainActor
final class MacroStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    private func makeStore() -> MacroStore {
        MacroStore(directory: tempDir)
    }

    private func makeEvent(
        keyCode: UInt16 = 8,
        modifiers: UInt = 0,
        characters: String = "c",
        charactersIgnoringModifiers: String = "c"
    ) -> KeyEventRecord {
        KeyEventRecord(
            keyCode: keyCode,
            modifiers: modifiers,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers
        )
    }

    private func makeMacro(
        name: String = "My Macro",
        events: [KeyEventRecord]? = nil
    ) -> Macro {
        Macro(name: name, events: events ?? [makeEvent()])
    }

    // MARK: - KeyEventRecord Codable round-trip

    func testKeyEventRecordCodableRoundTripPreservesAllFields() throws {
        let event = KeyEventRecord(
            keyCode: 36,
            modifiers: 131072,
            characters: "\r",
            charactersIgnoringModifiers: "\r"
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(KeyEventRecord.self, from: data)

        XCTAssertEqual(decoded, event)
    }

    // MARK: - init / empty dir

    func testEmptyDirLoadsNoMacros() {
        let store = makeStore()
        XCTAssertEqual(store.macros, [])
    }

    func testInitCreatesDirectoryOnDemand() {
        _ = makeStore()
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    // MARK: - add

    func testAddPersistsFileAndAppearsInMacros() throws {
        let store = makeStore()
        let macro = makeMacro()

        try store.add(macro)

        let fileURL = tempDir.appendingPathComponent("\(macro.id.uuidString).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(store.macros.contains(macro))
    }

    func testAddingSameIDTwiceReplacesInPlaceInsteadOfAppending() throws {
        let store = makeStore()
        let macro = makeMacro()

        try store.add(macro)
        var changed = macro
        changed.name = "Renamed"
        try store.add(changed)

        XCTAssertEqual(store.macros.count, 1)
        XCTAssertEqual(store.macros.first?.name, "Renamed")

        let contents = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(contents.filter { $0.pathExtension == "json" }.count, 1)
    }

    // MARK: - update

    func testUpdateRewritesFile() throws {
        let store = makeStore()
        var macro = makeMacro()
        try store.add(macro)

        macro.name = "Renamed"
        try store.update(macro)

        XCTAssertEqual(store.macros.first(where: { $0.id == macro.id })?.name, "Renamed")

        let fileURL = tempDir.appendingPathComponent("\(macro.id.uuidString).json")
        let reloaded = try JSONDecoder().decode(Macro.self, from: Data(contentsOf: fileURL))
        XCTAssertEqual(reloaded.name, "Renamed")
    }

    func testUpdateUnknownIDThrowsNotFound() {
        let store = makeStore()
        let macro = makeMacro(name: "Ghost")

        XCTAssertThrowsError(try store.update(macro)) { error in
            XCTAssertEqual(error as? MacroStoreError, .notFound(macro.id))
        }
    }

    // MARK: - delete

    func testDeleteRemovesFileAndFromMacros() throws {
        let store = makeStore()
        let macro = makeMacro()
        try store.add(macro)

        try store.delete(id: macro.id)

        let fileURL = tempDir.appendingPathComponent("\(macro.id.uuidString).json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(store.macros.contains(where: { $0.id == macro.id }))
    }

    func testDeleteUnknownIDDoesNotThrow() {
        let store = makeStore()
        XCTAssertNoThrow(try store.delete(id: UUID()))
    }

    // MARK: - persistence (reload)

    func testReloadViaNewInstanceSeesPersistedMacro() throws {
        let store1 = makeStore()
        let macro = makeMacro(name: "Persisted")
        try store1.add(macro)

        let store2 = makeStore()

        XCTAssertEqual(store2.macros.count, 1)
        XCTAssertEqual(store2.macros.first?.id, macro.id)
    }

    // MARK: - corrupt JSON self-heal

    func testCorruptMacroFileIsSkippedWithoutCrashingLoad() throws {
        let store1 = makeStore()
        let good = makeMacro(name: "Good")
        try store1.add(good)

        try Data("not json {{{".utf8).write(to: tempDir.appendingPathComponent("\(UUID().uuidString).json"))

        let store2 = makeStore()
        XCTAssertEqual(store2.macros.count, 1)
        XCTAssertEqual(store2.macros.first?.id, good.id)
    }
}
