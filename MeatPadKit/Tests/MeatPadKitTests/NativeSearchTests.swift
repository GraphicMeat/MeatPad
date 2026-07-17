import XCTest
@testable import MeatPadKit

final class NativeSearchTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    @discardableResult
    private func makeFile(_ relativePath: String, _ contents: String, in dir: URL? = nil) throws -> URL {
        let url = (dir ?? tempDir).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    // MARK: - literal matching

    func testLiteralCaseInsensitiveHitLineNumberAndRange() async throws {
        try makeFile("a.txt", "Hello World\nfoo BAR baz\n")

        let matches = try await NativeSearch().search(SearchQuery(pattern: "bar"), in: tempDir)

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.lineNumber, 2)
        XCTAssertEqual(matches.first?.lineText, "foo BAR baz")
        XCTAssertEqual(matches.first?.rangeInLine, 4..<7)
    }

    func testCaseSensitiveRespected() async throws {
        try makeFile("a.txt", "foo BAR baz\n")

        let insensitiveMiss = try await NativeSearch().search(
            SearchQuery(pattern: "bar", caseSensitive: true), in: tempDir
        )
        XCTAssertEqual(insensitiveMiss.count, 0)

        let hit = try await NativeSearch().search(
            SearchQuery(pattern: "BAR", caseSensitive: true), in: tempDir
        )
        XCTAssertEqual(hit.count, 1)
    }

    func testWholeWordDoesNotMatchSubstring() async throws {
        try makeFile("a.txt", "cat concatenate cat\n")

        let matches = try await NativeSearch().search(
            SearchQuery(pattern: "cat", wholeWord: true), in: tempDir
        )

        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches.map(\.rangeInLine), [0..<3, 16..<19])
    }

    // MARK: - regex

    func testRegexWithCapture() async throws {
        try makeFile("a.txt", "name: John\n")

        let matches = try await NativeSearch().search(
            SearchQuery(pattern: "(\\w+): (\\w+)", isRegex: true), in: tempDir
        )

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.rangeInLine, 0..<10) // "name: John"
    }

    // MARK: - skip rules

    func testBinaryFileSkipped() async throws {
        var binary = Data("needle".utf8)
        binary.insert(0, at: 0) // NUL byte in first 8KB
        try binary.write(to: tempDir.appendingPathComponent("bin.dat"))
        try makeFile("text.txt", "no match here\n")

        let matches = try await NativeSearch().search(SearchQuery(pattern: "needle"), in: tempDir)

        XCTAssertEqual(matches.count, 0)
    }

    func testIgnoredDirSkipped() async throws {
        try makeFile("inside.txt", "needle\n", in: tempDir.appendingPathComponent(".git", isDirectory: true))
        try makeFile("keep.txt", "no match\n")

        let matches = try await NativeSearch().search(SearchQuery(pattern: "needle"), in: tempDir)

        XCTAssertEqual(matches.count, 0)
    }

    // MARK: - multi-file sort

    func testMultiFileResultsSorted() async throws {
        try makeFile("b.txt", "needle\n")
        try makeFile("a.txt", "needle\n")

        let matches = try await NativeSearch().search(SearchQuery(pattern: "needle"), in: tempDir)

        XCTAssertEqual(matches.map(\.file.lastPathComponent), ["a.txt", "b.txt"])
    }

    // MARK: - UTF-16 offsets (non-ASCII)

    func testRangeInLineUsesUTF16OffsetsForMultibyteCharacters() async throws {
        // 😀 is a surrogate pair -> 2 UTF-16 units, so "cat" starts at UTF-16 offset 2, not 1.
        try makeFile("a.txt", "\u{1F600}cat\n")

        let matches = try await NativeSearch().search(SearchQuery(pattern: "cat", caseSensitive: true), in: tempDir)

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.rangeInLine, 2..<5)
    }

    // MARK: - replaceAll

    func testReplaceAllRewritesBothFilesAndCountsCorrect() async throws {
        let fileA = try makeFile("a.txt", "needle one\n")
        let fileB = try makeFile("b.txt", "needle two\n")
        let query = SearchQuery(pattern: "needle")
        let matches = try await NativeSearch().search(query, in: tempDir)

        let result = try SearchReplacer.replaceAll(matches: matches, with: "gone", query: query)

        XCTAssertEqual(result.replaced, 2)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(try String(contentsOf: fileA, encoding: .utf8), "gone one\n")
        XCTAssertEqual(try String(contentsOf: fileB, encoding: .utf8), "gone two\n")
    }

    func testReplaceAllStaleMatchSkipsFile() async throws {
        let fileA = try makeFile("a.txt", "needle one\n")
        let query = SearchQuery(pattern: "needle")
        let matches = try await NativeSearch().search(query, in: tempDir)

        // Mutate the file after search but before replace -> recorded match is now stale.
        try Data("changed entirely\n".utf8).write(to: fileA)

        let result = try SearchReplacer.replaceAll(matches: matches, with: "gone", query: query)

        XCTAssertEqual(result.replaced, 0)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(try String(contentsOf: fileA, encoding: .utf8), "changed entirely\n")
    }

    func testRegexReplaceWithCaptureGroup() async throws {
        let fileA = try makeFile("a.txt", "name: John\n")
        let query = SearchQuery(pattern: "(\\w+): (\\w+)", isRegex: true)
        let matches = try await NativeSearch().search(query, in: tempDir)

        let result = try SearchReplacer.replaceAll(matches: matches, with: "$2: $1", query: query)

        XCTAssertEqual(result.replaced, 1)
        XCTAssertEqual(try String(contentsOf: fileA, encoding: .utf8), "John: name\n")
    }
}
