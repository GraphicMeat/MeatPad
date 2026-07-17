import XCTest
@testable import MeatPadKit

@MainActor
final class ThemeStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    private func makeStore() -> ThemeStore {
        ThemeStore(directory: tempDir)
    }

    private func makeTheme(id: String = "user-\(UUID().uuidString)", name: String = "My Theme") -> Theme {
        Theme(
            id: id,
            name: name,
            isDark: true,
            editorBackground: RGBAColor(r: 0, g: 0, b: 0),
            editorForeground: RGBAColor(r: 1, g: 1, b: 1),
            currentLine: RGBAColor(r: 0.1, g: 0.1, b: 0.1),
            selection: RGBAColor(r: 0.2, g: 0.2, b: 0.2),
            caret: RGBAColor(r: 1, g: 1, b: 1),
            gutterForeground: RGBAColor(r: 0.5, g: 0.5, b: 0.5),
            tokenColors: [:]
        )
    }

    // MARK: - init / empty dir

    func testEmptyDirLoadsBuiltinsOnly() {
        let store = makeStore()
        XCTAssertEqual(store.userThemes, [])
        XCTAssertEqual(store.allThemes.map(\.id), BuiltinThemes.all.map(\.id))
    }

    func testInitCreatesUserDirectoryOnDemand() {
        _ = makeStore()
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    // MARK: - theme(id:) / isBuiltin

    func testThemeByIDFindsBuiltinAndUser() throws {
        let store = makeStore()
        XCTAssertEqual(store.theme(id: BuiltinThemes.defaultDark.id), BuiltinThemes.defaultDark)

        let custom = makeTheme()
        try store.save(custom)
        XCTAssertEqual(store.theme(id: custom.id), custom)
    }

    func testThemeByUnknownIDReturnsNil() {
        let store = makeStore()
        XCTAssertNil(store.theme(id: "nope"))
    }

    func testIsBuiltinTrueForBuiltinFalseForUser() throws {
        let store = makeStore()
        XCTAssertTrue(store.isBuiltin(id: BuiltinThemes.defaultDark.id))
        XCTAssertFalse(store.isBuiltin(id: "user-abc"))
    }

    // MARK: - save

    func testSavePersistsFileAndAppearsInUserThemesAndAllThemes() throws {
        let store = makeStore()
        let theme = makeTheme()

        try store.save(theme)

        let fileURL = tempDir.appendingPathComponent("\(theme.id).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(store.userThemes.contains(theme))
        XCTAssertTrue(store.allThemes.contains(theme))
    }

    func testSavingSameIDTwiceReplacesInPlace() throws {
        let store = makeStore()
        let theme = makeTheme()
        try store.save(theme)

        var changed = theme
        changed.name = "Renamed"
        try store.save(changed)

        XCTAssertEqual(store.userThemes.count, 1)
        XCTAssertEqual(store.userThemes.first?.name, "Renamed")
    }

    func testSaveBuiltinIDThrows() {
        let store = makeStore()
        let fakeBuiltin = makeTheme(id: BuiltinThemes.defaultDark.id)

        XCTAssertThrowsError(try store.save(fakeBuiltin))
        XCTAssertTrue(store.userThemes.isEmpty)
    }

    // MARK: - delete

    func testDeleteRemovesFileAndFromUserThemes() throws {
        let store = makeStore()
        let theme = makeTheme()
        try store.save(theme)

        try store.delete(id: theme.id)

        let fileURL = tempDir.appendingPathComponent("\(theme.id).json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(store.userThemes.contains(where: { $0.id == theme.id }))
    }

    func testDeleteBuiltinIDThrows() {
        let store = makeStore()
        XCTAssertThrowsError(try store.delete(id: BuiltinThemes.defaultDark.id))
        XCTAssertTrue(BuiltinThemes.all.contains(BuiltinThemes.defaultDark))
    }

    // MARK: - duplicate

    func testDuplicateBuiltinCreatesPersistedUserCopyWithSuffixedName() throws {
        let store = makeStore()
        let copy = try store.duplicate(id: BuiltinThemes.defaultDark.id)

        XCTAssertEqual(copy.name, "\(BuiltinThemes.defaultDark.name) Copy")
        XCTAssertTrue(copy.id.hasPrefix("user-"))
        XCTAssertNotEqual(copy.id, BuiltinThemes.defaultDark.id)
        XCTAssertTrue(store.userThemes.contains(copy))

        let fileURL = tempDir.appendingPathComponent("\(copy.id).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testDuplicateUnknownIDThrowsNotFound() {
        let store = makeStore()
        XCTAssertThrowsError(try store.duplicate(id: "nope")) { error in
            XCTAssertEqual(error as? ThemeStoreError, .notFound("nope"))
        }
    }

    // MARK: - persistence (reload)

    func testReloadViaNewInstanceSeesPersistedUserTheme() throws {
        let store1 = makeStore()
        let theme = makeTheme()
        try store1.save(theme)

        let store2 = makeStore()

        XCTAssertEqual(store2.userThemes.count, 1)
        XCTAssertEqual(store2.userThemes.first?.id, theme.id)
    }

    // MARK: - corrupt JSON self-heal

    func testCorruptUserThemeFileIsSkippedWithoutCrashingLoad() throws {
        let store1 = makeStore()
        let good = makeTheme()
        try store1.save(good)

        try Data("not json {{{".utf8).write(to: tempDir.appendingPathComponent("garbage.json"))

        let store2 = makeStore()
        XCTAssertEqual(store2.userThemes.count, 1)
        XCTAssertEqual(store2.userThemes.first?.id, good.id)
    }
}
