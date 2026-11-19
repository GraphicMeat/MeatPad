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

    // MARK: - Token

    private let token = String(repeating: "0123456789abcdef", count: 4)

    func testTheTokenTravelsInTheURLAndRoundTrips() throws {
        let request = try XCTUnwrap(NewFileRequest(directory: folder, fileExtension: "md", token: token))
        let components = try XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "token" })?.value, token)
        let parsed = try XCTUnwrap(NewFileRequest(url: request.url))
        XCTAssertEqual(parsed.token, token)
        XCTAssertEqual(parsed, request)
    }

    func testAnAwkwardTokenRoundTrips() throws {
        let odd = "a&b=c+d#e?f%g h"
        let request = try XCTUnwrap(NewFileRequest(directory: folder, fileExtension: "md", token: odd))
        XCTAssertEqual(NewFileRequest(url: request.url)?.token, odd, request.url.absoluteString)
    }

    func testARequestWithoutATokenHasNoTokenItem() throws {
        for request in [
            try XCTUnwrap(NewFileRequest(directory: folder, fileExtension: "md")),
            try XCTUnwrap(NewFileRequest(directory: folder, fileExtension: "md", token: nil)),
            try XCTUnwrap(NewFileRequest(directory: folder, fileExtension: "md", token: "")),
        ] {
            let components = try XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.queryItems?.map(\.name), ["dir", "ext"], request.url.absoluteString)
        }
        XCTAssertNil(NewFileRequest(directory: folder, fileExtension: "md")?.token)
    }

    func testAMissingOrEmptyTokenParsesAsNil() throws {
        let missing = try XCTUnwrap(NewFileRequest(url: url("meatpad://new-file?dir=/tmp&ext=md")))
        XCTAssertNil(missing.token)
        let empty = try XCTUnwrap(NewFileRequest(url: url("meatpad://new-file?dir=/tmp&ext=md&token=")))
        XCTAssertNil(empty.token)
        let present = try XCTUnwrap(NewFileRequest(url: url("meatpad://new-file?dir=/tmp&ext=md&token=\(token)")))
        XCTAssertEqual(present.token, token)
    }

    // MARK: - Dot-dot and standardising

    func testADirectoryWithADotDotComponentIsRejected() {
        for dir in ["/Users/x/../y", "/..", "/a/..", "/a/../", "/../a"] {
            XCTAssertNil(NewFileRequest(url: handBuilt([
                URLQueryItem(name: "dir", value: dir), URLQueryItem(name: "ext", value: "md"),
            ])), "dir \(dir)")
        }
    }

    func testAFolderWhoseNameMerelyContainsDotsIsAccepted() throws {
        for dir in ["/a/..b", "/a/b..", "/a/..."] {
            let parsed = try XCTUnwrap(NewFileRequest(url: handBuilt([
                URLQueryItem(name: "dir", value: dir), URLQueryItem(name: "ext", value: "md"),
            ])), "dir \(dir)")
            XCTAssertEqual(parsed.directory.path, dir)
        }
    }

    func testTheDirectoryIsStoredStandardised() throws {
        let parsed = try XCTUnwrap(NewFileRequest(url: handBuilt([
            URLQueryItem(name: "dir", value: "/a/./b//c/"), URLQueryItem(name: "ext", value: "md"),
        ])))
        XCTAssertEqual(parsed.directory.path, "/a/b/c")
    }

    // MARK: - Trust

    private func request(token: String?) -> NewFileRequest {
        NewFileRequest(directory: folder, fileExtension: "md", token: token)!
    }

    func testAMatchingUsableTokenIsTrusted() {
        XCTAssertEqual(request(token: token).trust(expectedToken: token), .trusted)
    }

    func testEverythingElseNeedsConfirmation() {
        let other = String(repeating: "f", count: 64)
        XCTAssertEqual(request(token: nil).trust(expectedToken: token), .needsConfirmation, "no request token")
        XCTAssertEqual(request(token: other).trust(expectedToken: token), .needsConfirmation, "wrong token")
        XCTAssertEqual(request(token: token).trust(expectedToken: nil), .needsConfirmation, "expected nil")
        XCTAssertEqual(request(token: nil).trust(expectedToken: nil), .needsConfirmation, "both nil")
        XCTAssertEqual(request(token: "").trust(expectedToken: ""), .needsConfirmation, "both empty")
        XCTAssertEqual(request(token: "abc").trust(expectedToken: "abc"), .needsConfirmation, "too short")
    }

    func testAParsedRequestWithTheRightTokenIsTrusted() throws {
        let sent = try XCTUnwrap(NewFileRequest(directory: folder, fileExtension: "md", token: token))
        let parsed = try XCTUnwrap(NewFileRequest(url: sent.url))
        XCTAssertEqual(parsed.trust(expectedToken: token), .trusted)
    }
}
