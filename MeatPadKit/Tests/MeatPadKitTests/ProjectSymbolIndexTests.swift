import XCTest
@testable import MeatPadKit

final class ProjectSymbolIndexTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectSymbolIndexTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    private func write(_ name: String, _ contents: String) -> URL {
        let url = tempDir.appendingPathComponent(name)
        try? Data(contents.utf8).write(to: url)
        return url
    }

    // MARK: - Basic build + prefix lookup

    func testBuildIndexesIdentifiersAcrossFiles() async {
        let a = write("a.swift", "func noteStore() {}")
        let b = write("b.swift", "let notepad = 1")
        let index = ProjectSymbolIndex()
        await index.build(files: [a, b])

        let result = index.complete(prefix: "not", excludingFile: nil, limit: 20)
        XCTAssertEqual(Set(result), ["noteStore", "notepad"])
    }

    // MARK: - Frequency ranking, ties alphabetical

    func testCompleteRanksByTotalFrequencyDescThenAlphabetical() async {
        let a = write("a.swift", "noteAlpha noteAlpha noteAlpha")
        let b = write("b.swift", "noteBeta noteBeta")
        let c = write("c.swift", "noteGamma")
        let index = ProjectSymbolIndex()
        await index.build(files: [a, b, c])

        let result = index.complete(prefix: "note", excludingFile: nil, limit: 20)
        XCTAssertEqual(result, ["noteAlpha", "noteBeta", "noteGamma"])
    }

    func testCompleteTiesBrokenAlphabetically() async {
        let a = write("a.swift", "noteZebra noteApple")
        let index = ProjectSymbolIndex()
        await index.build(files: [a])

        let result = index.complete(prefix: "note", excludingFile: nil, limit: 20)
        XCTAssertEqual(result, ["noteApple", "noteZebra"])
    }

    // MARK: - excludingFile

    func testExcludingFileDropsSoloContributionsButKeepsSharedWords() async {
        let a = write("a.swift", "onlyInA sharedWord")
        let b = write("b.swift", "sharedWord")
        let index = ProjectSymbolIndex()
        await index.build(files: [a, b])

        let result = index.complete(prefix: "", excludingFile: a, limit: 20)
        XCTAssertFalse(result.contains("onlyInA"), "word contributed only by the excluded file must be dropped")
        XCTAssertTrue(result.contains("sharedWord"), "word shared with another file must survive exclusion")
    }

    // MARK: - updateFile / removeFile

    func testUpdateFileReplacesThatFilesWords() async {
        let a = write("a.swift", "oldWord")
        let index = ProjectSymbolIndex()
        await index.build(files: [a])
        XCTAssertTrue(index.complete(prefix: "old", excludingFile: nil, limit: 20).contains("oldWord"))

        _ = write("a.swift", "newWord")
        index.updateFile(a)

        XCTAssertFalse(index.complete(prefix: "old", excludingFile: nil, limit: 20).contains("oldWord"))
        XCTAssertTrue(index.complete(prefix: "new", excludingFile: nil, limit: 20).contains("newWord"))
    }

    func testRemoveFileDropsItsWords() async {
        let a = write("a.swift", "onlyHere")
        let index = ProjectSymbolIndex()
        await index.build(files: [a])
        XCTAssertTrue(index.complete(prefix: "only", excludingFile: nil, limit: 20).contains("onlyHere"))

        index.removeFile(a)

        XCTAssertFalse(index.complete(prefix: "only", excludingFile: nil, limit: 20).contains("onlyHere"))
    }

    func testUpdateFileOnUnreadableURLRemovesContribution() async {
        let a = write("a.swift", "goneWord")
        let index = ProjectSymbolIndex()
        await index.build(files: [a])
        try? FileManager.default.removeItem(at: a)

        index.updateFile(a)

        XCTAssertFalse(index.complete(prefix: "gone", excludingFile: nil, limit: 20).contains("goneWord"))
    }

    // MARK: - build supersedes prior build

    func testRebuildWithShrunkenFileListDropsOldContributions() async {
        let a = write("a.swift", "aliveWord")
        let b = write("b.swift", "shrinkingWord")
        let index = ProjectSymbolIndex()
        await index.build(files: [a, b])
        XCTAssertTrue(index.complete(prefix: "shrink", excludingFile: nil, limit: 20).contains("shrinkingWord"))

        await index.build(files: [a])

        XCTAssertFalse(index.complete(prefix: "shrink", excludingFile: nil, limit: 20).contains("shrinkingWord"))
        XCTAssertTrue(index.complete(prefix: "alive", excludingFile: nil, limit: 20).contains("aliveWord"))
    }

    // MARK: - Binary + oversize skipped

    func testBinaryFileIsSkipped() async {
        var bytes = Data("someWord ".utf8)
        bytes.append(0) // NUL in first 8KB marks binary
        bytes.append(Data("more".utf8))
        let url = tempDir.appendingPathComponent("bin.dat")
        try? bytes.write(to: url)

        let index = ProjectSymbolIndex()
        await index.build(files: [url])

        XCTAssertFalse(index.complete(prefix: "some", excludingFile: nil, limit: 20).contains("someWord"))
    }

    func testOversizeFileIsSkipped() async {
        let url = tempDir.appendingPathComponent("huge.txt")
        // Just over the 4MB cap; padding chars aren't identifier chars so a
        // false-positive match here means the size cap wasn't applied.
        let padding = String(repeating: "x ", count: 2_100_001) // > 4MB of UTF-8 bytes
        try? Data((padding + " hugeWord").utf8).write(to: url)

        let index = ProjectSymbolIndex()
        await index.build(files: [url])

        XCTAssertFalse(index.complete(prefix: "huge", excludingFile: nil, limit: 20).contains("hugeWord"))
    }

    // MARK: - Case handling

    func testCompleteIsCaseInsensitiveAndPreservesHighestCountCaseVariant() async {
        let a = write("a.swift", "Note Note note")
        let index = ProjectSymbolIndex()
        await index.build(files: [a])

        let result = index.complete(prefix: "NO", excludingFile: nil, limit: 20)
        XCTAssertEqual(result, ["Note"], "exact-case variant with the highest count should be output")
    }

    // MARK: - Short words excluded (ponytail ceiling: length >= 3)

    func testWordsShorterThanThreeCharsAreNotIndexed() async {
        let a = write("a.swift", "if ok abc")
        let index = ProjectSymbolIndex()
        await index.build(files: [a])

        XCTAssertTrue(index.complete(prefix: "i", excludingFile: nil, limit: 20).isEmpty)
        XCTAssertTrue(index.complete(prefix: "ok", excludingFile: nil, limit: 20).isEmpty)
        XCTAssertTrue(index.complete(prefix: "abc", excludingFile: nil, limit: 20).contains("abc"))
    }

    // MARK: - Determinism

    func testSameInputProducesSameOutputOrder() async {
        let a = write("a.swift", "alpha beta gamma alpha beta alpha")
        let index1 = ProjectSymbolIndex()
        await index1.build(files: [a])
        let index2 = ProjectSymbolIndex()
        await index2.build(files: [a])

        let r1 = index1.complete(prefix: "", excludingFile: nil, limit: 20)
        let r2 = index2.complete(prefix: "", excludingFile: nil, limit: 20)
        XCTAssertEqual(r1, r2)
    }

    // MARK: - Limit respected

    func testLimitIsRespected() async {
        let contents = (0..<30).map { "notion\($0)" }.joined(separator: " ")
        let a = write("a.swift", contents)
        let index = ProjectSymbolIndex()
        await index.build(files: [a])

        let result = index.complete(prefix: "not", excludingFile: nil, limit: 5)
        XCTAssertEqual(result.count, 5)
    }

    // MARK: - Cancellation

    func testBuildChecksCancellation() async {
        let files = (0..<5).map { write("f\($0).swift", "word\($0)") }
        let index = ProjectSymbolIndex()
        let task = Task {
            await index.build(files: files)
        }
        task.cancel()
        _ = await task.value
        // No crash / hang is the assertion here; a cancelled build may index
        // a partial prefix of files, so just confirm it completes promptly.
    }
}
