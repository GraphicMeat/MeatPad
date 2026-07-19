import XCTest
@testable import MeatPadKit

final class BundleImporterTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    // MARK: - Fixture helpers

    private func makeBundleDir(named name: String = "Test.tmbundle") -> URL {
        let bundleURL = tempDir.appendingPathComponent(name, isDirectory: true)
        try! FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        return bundleURL
    }

    private func writeSnippet(
        in bundleURL: URL,
        filename: String,
        content: String?,
        name: String?,
        tabTrigger: String?,
        scope: String? = nil
    ) throws {
        let snippetsDir = bundleURL.appendingPathComponent("Snippets", isDirectory: true)
        try FileManager.default.createDirectory(at: snippetsDir, withIntermediateDirectories: true)

        var entries: [String] = []
        if let content { entries.append(plistEntry(key: "content", value: content)) }
        if let name { entries.append(plistEntry(key: "name", value: name)) }
        if let tabTrigger { entries.append(plistEntry(key: "tabTrigger", value: tabTrigger)) }
        if let scope { entries.append(plistEntry(key: "scope", value: scope)) }

        let xml = plistXML(entries: entries)
        try Data(xml.utf8).write(to: snippetsDir.appendingPathComponent(filename))
    }

    private func writeCommand(
        in bundleURL: URL,
        filename: String,
        command: String?,
        name: String?,
        input: String?,
        output: String?,
        scope: String? = nil
    ) throws {
        let commandsDir = bundleURL.appendingPathComponent("Commands", isDirectory: true)
        try FileManager.default.createDirectory(at: commandsDir, withIntermediateDirectories: true)

        var entries: [String] = []
        if let command { entries.append(plistEntry(key: "command", value: command)) }
        if let name { entries.append(plistEntry(key: "name", value: name)) }
        if let input { entries.append(plistEntry(key: "input", value: input)) }
        if let output { entries.append(plistEntry(key: "output", value: output)) }
        if let scope { entries.append(plistEntry(key: "scope", value: scope)) }

        let xml = plistXML(entries: entries)
        try Data(xml.utf8).write(to: commandsDir.appendingPathComponent(filename))
    }

    private func plistEntry(key: String, value: String) -> String {
        "<key>\(key)</key>\n<string>\(value)</string>"
    }

    private func plistXML(entries: [String]) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \(entries.joined(separator: "\n"))
        </dict>
        </plist>
        """
    }

    // MARK: - Snippet import

    func testSnippetWithTabTriggerImports() throws {
        let bundle = makeBundleDir()
        try writeSnippet(in: bundle, filename: "log.tmSnippet", content: "console.log($1);$0", name: "Console Log", tabTrigger: "log", scope: "source.js")

        let result = try BundleImporter.importBundle(at: bundle)

        XCTAssertEqual(result.snippets.count, 1)
        let snippet = result.snippets[0]
        XCTAssertEqual(snippet.name, "Console Log")
        XCTAssertEqual(snippet.trigger, "log")
        XCTAssertEqual(snippet.body, "console.log($1);$0")
        XCTAssertEqual(snippet.languageIDs, ["javascript"])
        XCTAssertEqual(result.skippedSnippets, 0)
    }

    func testSnippetWithRegexTransformBodyIsSkipped() throws {
        let bundle = makeBundleDir()
        try writeSnippet(in: bundle, filename: "xform.tmSnippet", content: "${1/foo/bar/}", name: "Transform", tabTrigger: "xf")

        let result = try BundleImporter.importBundle(at: bundle)

        XCTAssertEqual(result.snippets.count, 0)
        XCTAssertEqual(result.skippedSnippets, 1)
    }

    func testSnippetWithoutTabTriggerButShortNameDerivesTrigger() throws {
        let bundle = makeBundleDir()
        try writeSnippet(in: bundle, filename: "noTrigger.tmSnippet", content: "hello", name: "Log It!", tabTrigger: nil)

        let result = try BundleImporter.importBundle(at: bundle)

        XCTAssertEqual(result.snippets.count, 1)
        XCTAssertEqual(result.snippets[0].trigger, "logit")
        XCTAssertEqual(result.skippedSnippets, 0)
    }

    func testSnippetWithoutTabTriggerAndLongNameIsSkipped() throws {
        let bundle = makeBundleDir()
        let longName = "This Is A Very Long Snippet Name That Should Not Become A Trigger"
        try writeSnippet(in: bundle, filename: "noTriggerLong.tmSnippet", content: "hello", name: longName, tabTrigger: nil)

        let result = try BundleImporter.importBundle(at: bundle)

        XCTAssertEqual(result.snippets.count, 0)
        XCTAssertEqual(result.skippedSnippets, 1)
    }

    func testSnippetWithoutContentIsSkipped() throws {
        let bundle = makeBundleDir()
        try writeSnippet(in: bundle, filename: "noContent.tmSnippet", content: nil, name: "No Content", tabTrigger: "nc")

        let result = try BundleImporter.importBundle(at: bundle)

        XCTAssertEqual(result.snippets.count, 0)
        XCTAssertEqual(result.skippedSnippets, 1)
    }

    func testMalformedSnippetPlistIsSkippedAndCounted() throws {
        let bundle = makeBundleDir()
        let snippetsDir = bundle.appendingPathComponent("Snippets", isDirectory: true)
        try FileManager.default.createDirectory(at: snippetsDir, withIntermediateDirectories: true)
        try Data("not a plist {{{".utf8).write(to: snippetsDir.appendingPathComponent("garbage.tmSnippet"))

        let result = try BundleImporter.importBundle(at: bundle)

        XCTAssertEqual(result.snippets.count, 0)
        XCTAssertEqual(result.skippedSnippets, 1)
    }

    // MARK: - Command import: input mapping

    func testCommandInputSelectionMapsToSelection() throws {
        let bundle = makeBundleDir()
        try writeCommand(in: bundle, filename: "a.tmCommand", command: "echo hi", name: "A", input: "selection", output: nil)
        let result = try BundleImporter.importBundle(at: bundle)
        XCTAssertEqual(result.commands.first?.input, .selection)
    }

    func testCommandInputDocumentMapsToDocument() throws {
        let bundle = makeBundleDir()
        try writeCommand(in: bundle, filename: "a.tmCommand", command: "echo hi", name: "A", input: "document", output: nil)
        let result = try BundleImporter.importBundle(at: bundle)
        XCTAssertEqual(result.commands.first?.input, .document)
    }

    func testCommandInputEntireDocumentMapsToDocument() throws {
        let bundle = makeBundleDir()
        try writeCommand(in: bundle, filename: "a.tmCommand", command: "echo hi", name: "A", input: "entireDocument", output: nil)
        let result = try BundleImporter.importBundle(at: bundle)
        XCTAssertEqual(result.commands.first?.input, .document)
    }

    func testCommandInputUnknownOrMissingMapsToNone() throws {
        let bundle = makeBundleDir()
        try writeCommand(in: bundle, filename: "a.tmCommand", command: "echo hi", name: "A", input: "somethingElse", output: nil)
        try writeCommand(in: bundle, filename: "b.tmCommand", command: "echo hi", name: "B", input: nil, output: nil)
        let result = try BundleImporter.importBundle(at: bundle)
        XCTAssertEqual(result.commands.count, 2)
        XCTAssertTrue(result.commands.allSatisfy { $0.input == .none })
    }

    // MARK: - Command import: output mapping

    func testCommandOutputReplaceSelectedTextMapsToReplaceSelection() throws {
        let bundle = makeBundleDir()
        try writeCommand(in: bundle, filename: "a.tmCommand", command: "echo hi", name: "A", input: nil, output: "replaceSelectedText")
        let result = try BundleImporter.importBundle(at: bundle)
        XCTAssertEqual(result.commands.first?.output, .replaceSelection)
    }

    func testCommandOutputReplaceSelectionMapsToReplaceSelection() throws {
        let bundle = makeBundleDir()
        try writeCommand(in: bundle, filename: "a.tmCommand", command: "echo hi", name: "A", input: nil, output: "replaceSelection")
        let result = try BundleImporter.importBundle(at: bundle)
        XCTAssertEqual(result.commands.first?.output, .replaceSelection)
    }

    func testCommandOutputInsertAsTextMapsToInsertAtCaret() throws {
        let bundle = makeBundleDir()
        try writeCommand(in: bundle, filename: "a.tmCommand", command: "echo hi", name: "A", input: nil, output: "insertAsText")
        let result = try BundleImporter.importBundle(at: bundle)
        XCTAssertEqual(result.commands.first?.output, .insertAtCaret)
    }

    func testCommandOutputAfterSelectedTextMapsToInsertAtCaret() throws {
        let bundle = makeBundleDir()
        try writeCommand(in: bundle, filename: "a.tmCommand", command: "echo hi", name: "A", input: nil, output: "afterSelectedText")
        let result = try BundleImporter.importBundle(at: bundle)
        XCTAssertEqual(result.commands.first?.output, .insertAtCaret)
    }

    func testCommandOutputOpenAsNewDocumentMapsToNewNote() throws {
        let bundle = makeBundleDir()
        try writeCommand(in: bundle, filename: "a.tmCommand", command: "echo hi", name: "A", input: nil, output: "openAsNewDocument")
        let result = try BundleImporter.importBundle(at: bundle)
        XCTAssertEqual(result.commands.first?.output, .newNote)
    }

    func testCommandOutputCreateNewDocumentMapsToNewNote() throws {
        let bundle = makeBundleDir()
        try writeCommand(in: bundle, filename: "a.tmCommand", command: "echo hi", name: "A", input: nil, output: "createNewDocument")
        let result = try BundleImporter.importBundle(at: bundle)
        XCTAssertEqual(result.commands.first?.output, .newNote)
    }

    func testCommandOutputUnknownOrMissingMapsToOutputPanel() throws {
        let bundle = makeBundleDir()
        try writeCommand(in: bundle, filename: "a.tmCommand", command: "echo hi", name: "A", input: nil, output: "somethingWeird")
        try writeCommand(in: bundle, filename: "b.tmCommand", command: "echo hi", name: "B", input: nil, output: nil)
        let result = try BundleImporter.importBundle(at: bundle)
        XCTAssertEqual(result.commands.count, 2)
        XCTAssertTrue(result.commands.allSatisfy { $0.output == .outputPanel })
    }

    func testCommandNameAndScriptAndScopeImport() throws {
        let bundle = makeBundleDir()
        try writeCommand(in: bundle, filename: "a.tmCommand", command: "echo hi", name: "Say Hi", input: "selection", output: "replaceSelectedText", scope: "source.python")
        let result = try BundleImporter.importBundle(at: bundle)
        let command = try XCTUnwrap(result.commands.first)
        XCTAssertEqual(command.name, "Say Hi")
        XCTAssertEqual(command.script, "echo hi")
        XCTAssertEqual(command.languageIDs, ["python"])
    }

    func testCommandWithoutCommandKeyIsSkipped() throws {
        let bundle = makeBundleDir()
        try writeCommand(in: bundle, filename: "a.tmCommand", command: nil, name: "No Script", input: nil, output: nil)
        let result = try BundleImporter.importBundle(at: bundle)
        XCTAssertEqual(result.commands.count, 0)
        XCTAssertEqual(result.skippedCommands, 1)
    }

    func testMalformedCommandPlistIsSkippedAndCounted() throws {
        let bundle = makeBundleDir()
        let commandsDir = bundle.appendingPathComponent("Commands", isDirectory: true)
        try FileManager.default.createDirectory(at: commandsDir, withIntermediateDirectories: true)
        try Data("not a plist {{{".utf8).write(to: commandsDir.appendingPathComponent("garbage.tmCommand"))

        let result = try BundleImporter.importBundle(at: bundle)

        XCTAssertEqual(result.commands.count, 0)
        XCTAssertEqual(result.skippedCommands, 1)
    }

    // MARK: - Command import: provenance

    func testImportedCommandOriginIsImportedWithBundleNameAndInjectedDate() throws {
        let bundle = makeBundleDir(named: "MyStuff.tmbundle")
        try writeCommand(in: bundle, filename: "a.tmCommand", command: "echo hi", name: "A", input: nil, output: nil)
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

        let result = try BundleImporter.importBundle(at: bundle, now: fixedDate)

        let command = try XCTUnwrap(result.commands.first)
        XCTAssertEqual(command.origin, .imported(bundleName: "MyStuff.tmbundle", date: fixedDate))
    }

    func testImportedCommandIsUntrusted() throws {
        let bundle = makeBundleDir()
        try writeCommand(in: bundle, filename: "a.tmCommand", command: "echo hi", name: "A", input: nil, output: nil)

        let result = try BundleImporter.importBundle(at: bundle)

        XCTAssertEqual(result.commands.first?.trusted, false)
    }

    // MARK: - Bundle detection

    func testNonBundleDirectoryThrowsNotABundle() throws {
        let plainDir = tempDir.appendingPathComponent("NotABundle", isDirectory: true)
        try FileManager.default.createDirectory(at: plainDir, withIntermediateDirectories: true)

        XCTAssertThrowsError(try BundleImporter.importBundle(at: plainDir)) { error in
            XCTAssertEqual(error as? BundleImportError, .notABundle)
        }
    }

    func testDirectoryWithoutTmbundleExtensionButWithSnippetsFolderIsAccepted() throws {
        let dir = tempDir.appendingPathComponent("PlainNamedDir", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeSnippet(in: dir, filename: "log.tmSnippet", content: "hi", name: "Hi", tabTrigger: "hi")

        let result = try BundleImporter.importBundle(at: dir)
        XCTAssertEqual(result.snippets.count, 1)
    }

    func testDirectoryWithoutTmbundleExtensionButWithCommandsFolderIsAccepted() throws {
        let dir = tempDir.appendingPathComponent("PlainNamedDir2", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeCommand(in: dir, filename: "a.tmCommand", command: "echo hi", name: "A", input: nil, output: nil)

        let result = try BundleImporter.importBundle(at: dir)
        XCTAssertEqual(result.commands.count, 1)
    }

    // MARK: - scopeToLanguageIDs

    func testScopeToLanguageIDsKnownScopes() {
        XCTAssertEqual(BundleImporter.scopeToLanguageIDs("source.swift"), ["swift"])
        XCTAssertEqual(BundleImporter.scopeToLanguageIDs("source.js"), ["javascript"])
        XCTAssertEqual(BundleImporter.scopeToLanguageIDs("source.ts"), ["typescript"])
        XCTAssertEqual(BundleImporter.scopeToLanguageIDs("source.python"), ["python"])
        XCTAssertEqual(BundleImporter.scopeToLanguageIDs("source.py"), ["python"])
        XCTAssertEqual(BundleImporter.scopeToLanguageIDs("text.html.basic"), ["html"])
        XCTAssertEqual(BundleImporter.scopeToLanguageIDs("text.markdown"), ["markdown"])
        XCTAssertEqual(BundleImporter.scopeToLanguageIDs("text.md"), ["markdown"])
        XCTAssertEqual(BundleImporter.scopeToLanguageIDs("source.c"), ["c"])
        XCTAssertEqual(BundleImporter.scopeToLanguageIDs("source.ruby"), ["ruby"])
    }

    func testScopeToLanguageIDsUnknownOrNilReturnsEmpty() {
        XCTAssertEqual(BundleImporter.scopeToLanguageIDs("source.totally-unknown"), [])
        XCTAssertEqual(BundleImporter.scopeToLanguageIDs(nil), [])
    }

    func testScopeToLanguageIDsOnlyReturnsIDsPresentInLanguagesAll() {
        let knownIDs = Set(Languages.all.map(\.id))
        for scope in ["source.swift", "source.js", "source.ts", "source.python", "text.html.basic", "text.markdown", "source.c", "source.ruby"] {
            for id in BundleImporter.scopeToLanguageIDs(scope) {
                XCTAssertTrue(knownIDs.contains(id), "\(id) from scope \(scope) should exist in Languages.all")
            }
        }
    }
}
