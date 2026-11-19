import XCTest
@testable import FinderMenuKit

final class NewFileRequestTests: XCTestCase {

    private let folder = URL(fileURLWithPath: "/Users/me/Projects", isDirectory: true)

    private func url(_ string: String) -> URL { URL(string: string)! }

    /// Builds `meatpad://new-file?…` the way an outside caller would (the UI tests do this).
    private func handBuilt(scheme: String = "meatpad", host: String = "new-file", _ items: [URLQueryItem]) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = items
        return components.url!
    }

    func testTheURLIsMeatpadNewFileWithDirThenExt() throws {
        let request = try XCTUnwrap(NewFileRequest(directory: folder, fileExtension: "md"))
        let components = try XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "meatpad")
        XCTAssertEqual(components.host, "new-file")
        XCTAssertEqual(components.queryItems?.map(\.name), ["dir", "ext"])
        XCTAssertEqual(components.queryItems?.map(\.value), ["/Users/me/Projects", "md"])
        XCTAssertEqual(NewFileRequest.scheme, "meatpad")
        XCTAssertEqual(NewFileRequest.host, "new-file")
    }

    func testAnAwkwardPathSurvivesTheRoundTripByteForByte() throws {
        let path = "/Users/a b/ä&c=d#e?f+g%h"
        // `URL(fileURLWithPath:)` itself stores "ä" decomposed (NFD), before the codec is
        // involved — the bytes to preserve are the ones the request was given. Swift `==` on
        // String is canonical equivalence, so the literal still matches.
        let directory = URL(fileURLWithPath: path)
        let request = try XCTUnwrap(NewFileRequest(directory: directory, fileExtension: "md"))
        let parsed = try XCTUnwrap(NewFileRequest(url: request.url), request.url.absoluteString)
        XCTAssertEqual(Array(parsed.directory.path.utf8), Array(directory.path.utf8), request.url.absoluteString)
        XCTAssertEqual(parsed.directory.path, path)
        XCTAssertEqual(parsed.fileExtension, "md")
        XCTAssertEqual(parsed, request)
    }

    func testAHandBuiltURLParses() throws {
        let parsed = try XCTUnwrap(NewFileRequest(url: handBuilt([
            URLQueryItem(name: "dir", value: "/tmp/Some Folder"),
            URLQueryItem(name: "ext", value: "txt"),
        ])))
        XCTAssertEqual(parsed.directory.path, "/tmp/Some Folder")
        XCTAssertEqual(parsed.fileExtension, "txt")
    }

    func testTheSchemeIsCaseInsensitive() {
        XCTAssertNotNil(NewFileRequest(url: url("MeatPad://new-file?dir=/tmp&ext=md")))
    }

    func testTheWrongSchemeOrHostIsRejected() {
        XCTAssertNil(NewFileRequest(url: url("https://new-file?dir=/tmp&ext=md")))
        XCTAssertNil(NewFileRequest(url: url("meatpad://open?dir=/tmp&ext=md")))
        XCTAssertNil(NewFileRequest(url: url("meatpad:new-file?dir=/tmp&ext=md")))
        XCTAssertNil(NewFileRequest(url: URL(fileURLWithPath: "/tmp/new-file")))
    }

    func testMissingParametersAreRejected() {
        XCTAssertNil(NewFileRequest(url: url("meatpad://new-file?ext=md")))
        XCTAssertNil(NewFileRequest(url: url("meatpad://new-file?dir=/tmp")))
        XCTAssertNil(NewFileRequest(url: url("meatpad://new-file")))
        XCTAssertNil(NewFileRequest(url: url("meatpad://new-file?dir=&ext=md")))
    }

    func testARelativeDirectoryIsRejected() {
        XCTAssertNil(NewFileRequest(url: handBuilt([
            URLQueryItem(name: "dir", value: "relative"), URLQueryItem(name: "ext", value: "md"),
        ])))
        XCTAssertNil(NewFileRequest(url: handBuilt([
            URLQueryItem(name: "dir", value: "~/Desktop"), URLQueryItem(name: "ext", value: "md"),
        ])))
    }

    func testAnExtensionThatIsNotAlreadyCleanIsRejected() {
        for ext in ["a/b", "..", "../x", ".md", " md", "", "a b", String(repeating: "x", count: 17)] {
            XCTAssertNil(NewFileRequest(url: handBuilt([
                URLQueryItem(name: "dir", value: "/tmp"), URLQueryItem(name: "ext", value: ext),
            ])), "ext \(ext)")
            XCTAssertNil(NewFileRequest(directory: folder, fileExtension: ext), "ext \(ext)")
        }
    }

    func testARelativeDirectoryURLCannotMakeARequest() {
        XCTAssertNil(NewFileRequest(directory: URL(string: "relative/folder")!, fileExtension: "md"))
        XCTAssertNil(NewFileRequest(directory: URL(string: "https://example.com/x")!, fileExtension: "md"))
    }
}
