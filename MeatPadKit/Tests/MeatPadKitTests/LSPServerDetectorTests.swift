import XCTest
@testable import MeatPadKit

final class LSPServerDetectorTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    @discardableResult
    private func makeExecutable(_ relativePath: String) throws -> URL {
        let url = tempDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    // MARK: - well-known dirs (rust-analyzer via fake ~/.cargo/bin)

    func testFindsRustAnalyzerInFakeCargoBin() throws {
        let binary = try makeExecutable(".cargo/bin/rust-analyzer")
        let env = ["HOME": tempDir.path, "PATH": ""]

        let detected = LSPServerDetector.detect(userEnvironment: env, xcrunFinder: { nil })

        let rust = detected.first { $0.languageIDs.contains("rust") }
        XCTAssertEqual(rust?.binaryURL, binary)
        XCTAssertEqual(rust?.launchArguments, [])
        XCTAssertEqual(rust?.installHint, "rustup component add rust-analyzer")
        XCTAssertEqual(rust?.displayName, "rust-analyzer")
    }

    func testRustAnalyzerAbsentWhenNotFoundAnywhere() {
        let env = ["HOME": tempDir.path, "PATH": ""]
        let detected = LSPServerDetector.detect(userEnvironment: env, xcrunFinder: { nil })
        XCTAssertFalse(detected.contains { $0.languageIDs.contains("rust") })
    }

    // MARK: - PATH-split probing

    func testFindsServerViaPATHEntry() throws {
        let binary = try makeExecutable("custom/typescript-language-server")
        let env = ["HOME": tempDir.path, "PATH": tempDir.appendingPathComponent("custom").path]

        let detected = LSPServerDetector.detect(userEnvironment: env, xcrunFinder: { nil })

        XCTAssertEqual(detected.first { $0.languageIDs.contains("typescript") }?.binaryURL, binary)
    }

    func testPATHEntriesAreColonSplitAndSearchedInOrder() throws {
        let binary = try makeExecutable("dirB/pyright-langserver")
        let env = [
            "HOME": tempDir.path,
            "PATH": "\(tempDir.appendingPathComponent("dirA").path):\(tempDir.appendingPathComponent("dirB").path)",
        ]

        let detected = LSPServerDetector.detect(userEnvironment: env, xcrunFinder: { nil })

        XCTAssertEqual(detected.first { $0.languageIDs.contains("python") }?.binaryURL, binary)
    }

    // MARK: - launch arguments

    func testTypeScriptServerRequiresStdioFlag() throws {
        try makeExecutable("bin/typescript-language-server")
        let env = ["HOME": tempDir.path, "PATH": tempDir.appendingPathComponent("bin").path]

        let ts = LSPServerDetector.detect(userEnvironment: env, xcrunFinder: { nil })
            .first { $0.languageIDs.contains("typescript") }
        XCTAssertEqual(ts?.launchArguments, ["--stdio"])
        XCTAssertEqual(Set(ts?.languageIDs ?? []), ["typescript", "javascript", "tsx"])
    }

    func testPyrightRequiresStdioFlag() throws {
        try makeExecutable("bin/pyright-langserver")
        let env = ["HOME": tempDir.path, "PATH": tempDir.appendingPathComponent("bin").path]

        let pyright = LSPServerDetector.detect(userEnvironment: env, xcrunFinder: { nil })
            .first { $0.languageIDs.contains("python") }
        XCTAssertEqual(pyright?.launchArguments, ["--stdio"])
        XCTAssertEqual(pyright?.installHint, "npm install -g pyright")
    }

    // MARK: - executable bit is required

    func testNonExecutableFileIsNotDetected() throws {
        let path = tempDir.appendingPathComponent("bin/rust-analyzer")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not executable".utf8).write(to: path)
        // deliberately not chmod +x

        let env = ["HOME": tempDir.path, "PATH": tempDir.appendingPathComponent("bin").path]
        let detected = LSPServerDetector.detect(userEnvironment: env, xcrunFinder: { nil })
        XCTAssertFalse(detected.contains { $0.languageIDs.contains("rust") })
    }

    // MARK: - sourcekit-lsp via injected xcrunFinder

    func testFindsSourceKitLSPViaInjectedXcrunFinder() {
        let fakeURL = URL(fileURLWithPath: "/usr/bin/sourcekit-lsp")
        let env = ["HOME": tempDir.path, "PATH": ""]

        let detected = LSPServerDetector.detect(userEnvironment: env, xcrunFinder: { fakeURL })

        let swift = detected.first { $0.languageIDs.contains("swift") }
        XCTAssertEqual(swift?.binaryURL, fakeURL)
        XCTAssertEqual(swift?.launchArguments, [])
        XCTAssertEqual(swift?.installHint, "xcode-select --install")
        XCTAssertEqual(swift?.displayName, "SourceKit-LSP")
    }

    func testSourceKitLSPAbsentWhenXcrunFinderReturnsNil() {
        let env = ["HOME": tempDir.path, "PATH": ""]
        let detected = LSPServerDetector.detect(userEnvironment: env, xcrunFinder: { nil })
        XCTAssertFalse(detected.contains { $0.languageIDs.contains("swift") })
    }

    // MARK: - static catalog (install hints available even when absent)

    func testKnownServersCatalogListsAllFourServers() {
        let ids = Set(LSPServerDetector.knownServers.flatMap(\.languageIDs))
        XCTAssertEqual(ids, ["swift", "rust", "typescript", "javascript", "tsx", "python"])
    }

    func testKnownServersCatalogIncludesInstallHintsRegardlessOfDetection() {
        let env = ["HOME": tempDir.path, "PATH": ""]
        XCTAssertTrue(LSPServerDetector.detect(userEnvironment: env, xcrunFinder: { nil }).isEmpty)

        let rustHint = LSPServerDetector.knownServers.first { $0.languageIDs.contains("rust") }?.installHint
        XCTAssertEqual(rustHint, "rustup component add rust-analyzer")
    }
}
