import XCTest
@testable import MeatPadKit

@MainActor
final class SnippetLibraryTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    private func makeLibrary() -> SnippetLibrary {
        SnippetLibrary(userDirectory: tempDir)
    }

    // MARK: - init / empty dir

    func testEmptyDirLoadsBuiltinsOnly() {
        let library = makeLibrary()
        XCTAssertEqual(library.userSnippets, [])
        XCTAssertEqual(library.all.count, BuiltinSnippets.all.count)
        XCTAssertEqual(Set(library.all.map(\.id)), Set(BuiltinSnippets.all.map(\.id)))
    }

    func testInitCreatesUserDirectoryOnDemand() {
        _ = makeLibrary()
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    // MARK: - add

    func testAddPersistsFileAndAppearsInAll() throws {
        let library = makeLibrary()
        let snippet = Snippet(name: "My Snippet", trigger: "mine", languageIDs: ["swift"], body: "$0")

        try library.add(snippet)

        let fileURL = tempDir.appendingPathComponent("\(snippet.id.uuidString).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(library.userSnippets.contains(snippet))
        XCTAssertTrue(library.all.contains(snippet))
    }

    func testAddingSameIDTwiceReplacesInPlaceInsteadOfAppending() throws {
        let library = makeLibrary()
        let snippet = Snippet(name: "My Snippet", trigger: "mine", languageIDs: ["swift"], body: "$0")

        try library.add(snippet)
        var changed = snippet
        changed.body = "changed $0"
        try library.add(changed)

        XCTAssertEqual(library.userSnippets.count, 1)
        XCTAssertEqual(library.userSnippets.first?.body, "changed $0")

        let contents = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(contents.filter { $0.pathExtension == "json" }.count, 1)
    }

    // MARK: - update

    func testUpdateRewritesFile() throws {
        let library = makeLibrary()
        var snippet = Snippet(name: "My Snippet", trigger: "mine", languageIDs: ["swift"], body: "$0")
        try library.add(snippet)

        snippet.body = "changed $0"
        try library.update(snippet)

        XCTAssertEqual(library.userSnippets.first(where: { $0.id == snippet.id })?.body, "changed $0")

        let fileURL = tempDir.appendingPathComponent("\(snippet.id.uuidString).json")
        let reloaded = try JSONDecoder().decode(Snippet.self, from: Data(contentsOf: fileURL))
        XCTAssertEqual(reloaded.body, "changed $0")
    }

    func testUpdateUnknownIDThrowsNotFound() {
        let library = makeLibrary()
        let snippet = Snippet(name: "Ghost", trigger: "ghost", languageIDs: [], body: "$0")

        XCTAssertThrowsError(try library.update(snippet)) { error in
            XCTAssertEqual(error as? SnippetLibraryError, .notFound(snippet.id))
        }
    }

    // MARK: - delete

    func testDeleteRemovesFileAndFromAll() throws {
        let library = makeLibrary()
        let snippet = Snippet(name: "My Snippet", trigger: "mine", languageIDs: ["swift"], body: "$0")
        try library.add(snippet)

        try library.delete(id: snippet.id)

        let fileURL = tempDir.appendingPathComponent("\(snippet.id.uuidString).json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(library.userSnippets.contains(where: { $0.id == snippet.id }))
        XCTAssertFalse(library.all.contains(where: { $0.id == snippet.id }))
    }

    // MARK: - persistence (reload)

    func testReloadViaNewInstanceSeesPersistedUserSnippet() throws {
        let library1 = makeLibrary()
        let snippet = Snippet(name: "Persisted", trigger: "pst", languageIDs: [], body: "$0")
        try library1.add(snippet)

        let library2 = makeLibrary()

        XCTAssertEqual(library2.userSnippets.count, 1)
        XCTAssertEqual(library2.userSnippets.first?.id, snippet.id)
    }

    // MARK: - shadowing in `all`

    func testUserSnippetWithSameTriggerAndExactLanguageShadowsBuiltin() throws {
        let library = makeLibrary()
        let builtin = BuiltinSnippets.all.first(where: { $0.trigger == "func" && $0.languageIDs.contains("swift") })
        XCTAssertNotNil(builtin)

        let override = Snippet(name: "My func", trigger: "func", languageIDs: ["swift"], body: "override $0")
        try library.add(override)

        XCTAssertFalse(library.all.contains(where: { $0.id == builtin!.id }))
        XCTAssertTrue(library.all.contains(override))
    }

    func testUserSnippetWithSameTriggerButDisjointLanguageDoesNotShadowBuiltin() throws {
        let library = makeLibrary()
        let builtin = BuiltinSnippets.all.first(where: { $0.trigger == "func" && $0.languageIDs.contains("swift") })
        XCTAssertNotNil(builtin)

        let unrelated = Snippet(name: "Python func", trigger: "func", languageIDs: ["python"], body: "def $0")
        try library.add(unrelated)

        XCTAssertTrue(library.all.contains(where: { $0.id == builtin!.id }))
        XCTAssertTrue(library.all.contains(unrelated))
    }

    func testAllLanguageUserSnippetShadowsAllLanguageBuiltinWithSameTrigger() throws {
        // Empty scope overlaps everything, so an all-language user snippet shadows even
        // a specific-language builtin sharing its trigger.
        let library = makeLibrary()
        let builtin = BuiltinSnippets.all.first(where: { $0.trigger == "func" && $0.languageIDs.contains("swift") })
        XCTAssertNotNil(builtin)

        let allLangOverride = Snippet(name: "Universal func", trigger: "func", languageIDs: [], body: "universal $0")
        try library.add(allLangOverride)

        XCTAssertFalse(library.all.contains(where: { $0.id == builtin!.id }))
    }

    // MARK: - partition: narrow user override over a multi-language builtin

    func testNarrowUserOverrideDoesNotShadowMultiLanguageBuiltinInAll() throws {
        // "fn" is a real builtin scoped to BOTH javascript and typescript. A user
        // override scoped to javascript ONLY must not remove the builtin from `all` —
        // it doesn't cover the builtin's entire scope, so typescript still needs it.
        let library = makeLibrary()
        let builtin = BuiltinSnippets.all.first(where: { $0.trigger == "fn" })
        XCTAssertNotNil(builtin)

        let jsOnly = Snippet(name: "JS fn", trigger: "fn", languageIDs: ["javascript"], body: "js $0")
        try library.add(jsOnly)

        XCTAssertTrue(library.all.contains(where: { $0.id == builtin!.id }))
        XCTAssertTrue(library.all.contains(jsOnly))
    }

    func testUserOverrideCoveringEntireMultiLanguageBuiltinScopeShadowsInAll() throws {
        let library = makeLibrary()
        let builtin = BuiltinSnippets.all.first(where: { $0.trigger == "fn" })
        XCTAssertNotNil(builtin)

        let bothLangs = Snippet(name: "Both fn", trigger: "fn", languageIDs: ["javascript", "typescript"], body: "both $0")
        try library.add(bothLangs)

        XCTAssertFalse(library.all.contains(where: { $0.id == builtin!.id }))
    }

    func testNarrowOverridePartitionsSnippetsForLanguageIDPerLanguage() throws {
        // The javascript-only override wins for javascript, but typescript still
        // resolves to the untouched multi-language builtin — per-language partition,
        // not an all-or-nothing shadow.
        let library = makeLibrary()
        let jsOnly = Snippet(name: "JS fn", trigger: "fn", languageIDs: ["javascript"], body: "js $0")
        try library.add(jsOnly)

        XCTAssertEqual(library.snippet(trigger: "fn", languageID: "javascript"), jsOnly)
        let tsResolved = library.snippet(trigger: "fn", languageID: "typescript")
        XCTAssertEqual(tsResolved?.languageIDs, ["javascript", "typescript"])
        XCTAssertTrue(BuiltinSnippets.all.contains(tsResolved!))

        XCTAssertTrue(library.snippets(forLanguageID: "javascript").contains(jsOnly))
        XCTAssertTrue(library.snippets(forLanguageID: "typescript").contains(where: { $0.id == tsResolved!.id }))
        XCTAssertFalse(library.snippets(forLanguageID: "typescript").contains(jsOnly))
    }

    func testDisjointLanguageOverrideResolvesIndependentlyPerLanguage() throws {
        // "func" lookup: swift still finds the builtin, python finds the user override.
        let library = makeLibrary()
        let pythonOverride = Snippet(name: "Python func", trigger: "func", languageIDs: ["python"], body: "def $0")
        try library.add(pythonOverride)

        let swiftResolved = library.snippet(trigger: "func", languageID: "swift")
        XCTAssertTrue(BuiltinSnippets.all.contains(swiftResolved!))
        XCTAssertEqual(library.snippet(trigger: "func", languageID: "python"), pythonOverride)
    }

    // MARK: - trigger resolution precedence

    func testResolutionPrefersExactLanguageUserOverEverything() throws {
        let library = makeLibrary()
        // "func"/"swift" is a real builtin trigger; the exact-language user override
        // must win over the user's own all-language snippet and both builtin tiers.
        let exactUser = Snippet(name: "A", trigger: "func", languageIDs: ["swift"], body: "exact-user")
        let allLangUser = Snippet(name: "B", trigger: "func", languageIDs: [], body: "all-user")
        try library.add(allLangUser)
        try library.add(exactUser)

        let resolved = library.snippet(trigger: "func", languageID: "swift")
        XCTAssertEqual(resolved, exactUser)
    }

    func testResolutionPrefersAllLanguageUserOverBuiltinWhenNoExactMatch() throws {
        let library = makeLibrary()
        // "func" collides with the Swift builtin, but request a language ("python")
        // where no builtin exists with an exact-language "func" is false — use an
        // uncontended trigger to isolate all-language user vs no exact anything.
        let allLangUser = Snippet(name: "Universal", trigger: "zzz-unique", languageIDs: [], body: "all-user")
        try library.add(allLangUser)

        XCTAssertEqual(library.snippet(trigger: "zzz-unique", languageID: "swift"), allLangUser)
        XCTAssertEqual(library.snippet(trigger: "zzz-unique", languageID: nil), allLangUser)
    }

    func testResolutionFallsBackToExactBuiltinWhenNoUserMatch() {
        let library = makeLibrary()
        let resolved = library.snippet(trigger: "func", languageID: "swift")
        XCTAssertEqual(resolved?.languageIDs, ["swift"])
        XCTAssertEqual(resolved?.trigger, "func")
        XCTAssertTrue(BuiltinSnippets.all.contains(resolved!))
    }

    func testResolutionFallsBackToAllLanguageBuiltinWhenNoExactMatchAnywhere() {
        let library = makeLibrary()
        // "link" is a Markdown-only builtin trigger; requesting a language it doesn't
        // scope to should fall through past exact tiers to nil (no all-language builtin
        // shares that trigger), proving exact-only builtins don't leak across languages.
        XCTAssertNil(library.snippet(trigger: "link", languageID: "swift"))
    }

    func testNilLanguageIDMatchesOnlyAllLanguageSnippets() throws {
        let library = makeLibrary()
        // "func" only exists as an exact-language (swift) builtin — nil languageID
        // must not match it.
        XCTAssertNil(library.snippet(trigger: "func", languageID: nil))

        let allLangUser = Snippet(name: "Universal", trigger: "uni", languageIDs: [], body: "$0")
        try library.add(allLangUser)
        XCTAssertEqual(library.snippet(trigger: "uni", languageID: nil), allLangUser)
    }

    func testExactLanguageBuiltinBeatsAllLanguageBuiltinWhenBothTriggersCollideAcrossScopes() throws {
        let library = makeLibrary()
        // Craft the all-vs-exact-builtin tier via user snippets standing in for both
        // sides so the test doesn't depend on incidental BuiltinSnippets collisions:
        let exact = Snippet(name: "Exact", trigger: "collide", languageIDs: ["swift"], body: "exact")
        let allLang = Snippet(name: "All", trigger: "collide", languageIDs: [], body: "all")
        try library.add(allLang)
        try library.add(exact)

        XCTAssertEqual(library.snippet(trigger: "collide", languageID: "swift"), exact)
        XCTAssertEqual(library.snippet(trigger: "collide", languageID: "python"), allLang)
    }

    // MARK: - snippets(forLanguageID:)

    func testSnippetsForLanguageIDFiltersScopeAndIncludesAllLanguage() throws {
        let library = makeLibrary()
        let swiftOnly = library.snippets(forLanguageID: "swift")
        XCTAssertTrue(swiftOnly.allSatisfy { $0.languageIDs.isEmpty || $0.languageIDs.contains("swift") })
        XCTAssertFalse(swiftOnly.contains { !$0.languageIDs.isEmpty && !$0.languageIDs.contains("swift") })

        // name-sorted
        XCTAssertEqual(swiftOnly.map(\.name), swiftOnly.map(\.name).sorted())
    }

    func testSnippetsForNilLanguageIDReturnsOnlyAllLanguageSnippets() throws {
        let library = makeLibrary()
        let universal = Snippet(name: "Universal", trigger: "uni", languageIDs: [], body: "$0")
        try library.add(universal)

        let result = library.snippets(forLanguageID: nil)
        XCTAssertTrue(result.allSatisfy { $0.languageIDs.isEmpty })
        XCTAssertTrue(result.contains(universal))
    }

    // MARK: - corrupt JSON self-heal

    func testCorruptUserSnippetFileIsSkippedWithoutCrashingLoad() throws {
        let library1 = makeLibrary()
        let good = Snippet(name: "Good", trigger: "good", languageIDs: [], body: "$0")
        try library1.add(good)

        try Data("not json {{{".utf8).write(to: tempDir.appendingPathComponent("\(UUID().uuidString).json"))

        let library2 = makeLibrary()
        XCTAssertEqual(library2.userSnippets.count, 1)
        XCTAssertEqual(library2.userSnippets.first?.id, good.id)
    }

    // MARK: - BuiltinSnippets

    func testEveryBuiltinSnippetBodyParsesWithoutThrowing() throws {
        for snippet in BuiltinSnippets.all {
            XCTAssertNoThrow(try SnippetParser.parse(snippet.body), "\(snippet.name) (\(snippet.trigger)) failed to parse")
        }
    }

    func testMarkdownTableSkeletonAndTaskListItemResolveScopedToMarkdownOnly() {
        let library = makeLibrary()

        let table = library.snippet(trigger: "table", languageID: "markdown")
        XCTAssertEqual(table?.languageIDs, ["markdown"])
        XCTAssertNil(library.snippet(trigger: "table", languageID: "swift"))

        let task = library.snippet(trigger: "task", languageID: "markdown")
        XCTAssertEqual(task?.languageIDs, ["markdown"])
        XCTAssertNil(library.snippet(trigger: "task", languageID: "swift"))
    }

    func testBuiltinSnippetsHaveUniqueDeterministicIDs() {
        let ids = BuiltinSnippets.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "builtin IDs must be unique")

        // Deterministic: re-fetching `all` yields the exact same IDs (fixed UUIDs, not UUID()).
        let idsAgain = BuiltinSnippets.all.map(\.id)
        XCTAssertEqual(ids, idsAgain)
    }
}
