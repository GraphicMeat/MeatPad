import Foundation

/// A language server MeatPad found installed on the machine, ready to launch.
public struct DetectedServer: Equatable, Sendable {
    public let languageIDs: [String]
    public let binaryURL: URL
    public let launchArguments: [String]
    public let installHint: String
    public let displayName: String
}

/// Static facts about a known server, independent of whether it's installed — lets the
/// app show an install hint for a language even when `detect()` didn't find the binary.
public struct LSPServerSpec: Equatable, Sendable {
    public let languageIDs: [String]
    public let displayName: String
    public let installHint: String
}

/// Detects installed language servers by probing well-known install locations plus a
/// caller-supplied PATH. Detect-installed ONLY — never installs or downloads anything.
///
/// GUI apps launched from Finder don't inherit the shell's PATH, so `detect` never reads
/// `ProcessInfo.processInfo.environment` itself: callers must pass a shell-resolved
/// environment (e.g. `ProcessInfo.processInfo.userEnvironment` from LanguageClient).
/// This also keeps the function hermetic for tests — probe directories derived from
/// "home" read `userEnvironment["HOME"]`, not the real home directory.
public enum LSPServerDetector {
    private struct CatalogEntry {
        let languageIDs: [String]
        let displayName: String
        let installHint: String
        let binaryName: String
        let launchArguments: [String]
        /// Extra directories to probe before falling back to PATH. `home` is nil when
        /// `userEnvironment["HOME"]` was absent — implementations must omit any
        /// home-derived dir in that case rather than guessing a real home directory.
        let extraDirs: (_ home: String?) -> [String]
    }

    // ponytail: typescript-language-server/pyright's real global-bin location is
    // "npm config get prefix" + "/bin", which requires shelling out to npm. detect()'s
    // seams (userEnvironment/fileManager/xcrunFinder) don't cover that, and npm's global
    // bin is normally already on PATH anyway (that's the point of `npm install -g`), so
    // this only probes brew prefixes + PATH. Add an npmPrefixFinder seam if a real
    // install ever lands outside both.
    private static let catalog: [CatalogEntry] = [
        CatalogEntry(
            languageIDs: ["rust"],
            displayName: "rust-analyzer",
            installHint: "rustup component add rust-analyzer",
            binaryName: "rust-analyzer",
            launchArguments: [],
            extraDirs: { home in (home.map { ["\($0)/.cargo/bin"] } ?? []) + ["/opt/homebrew/bin", "/usr/local/bin"] }
        ),
        CatalogEntry(
            languageIDs: ["typescript", "javascript", "tsx"],
            displayName: "typescript-language-server",
            installHint: "npm install -g typescript-language-server typescript",
            binaryName: "typescript-language-server",
            launchArguments: ["--stdio"],
            extraDirs: { _ in ["/opt/homebrew/bin", "/usr/local/bin"] }
        ),
        CatalogEntry(
            languageIDs: ["python"],
            displayName: "pyright",
            installHint: "npm install -g pyright",
            binaryName: "pyright-langserver",
            launchArguments: ["--stdio"],
            extraDirs: { _ in ["/opt/homebrew/bin", "/usr/local/bin"] }
        ),
    ]

    private static let swiftSpec = LSPServerSpec(
        languageIDs: ["swift"],
        displayName: "SourceKit-LSP",
        installHint: "xcode-select --install"
    )

    /// Install-hint facts for every known server, regardless of whether it's installed —
    /// for a missing-server banner that needs a hint before (or without) detecting.
    public static var knownServers: [LSPServerSpec] {
        catalog.map { LSPServerSpec(languageIDs: $0.languageIDs, displayName: $0.displayName, installHint: $0.installHint) }
            + [swiftSpec]
    }

    public static func detect(
        userEnvironment: [String: String],
        fileManager: FileManager = .default,
        xcrunFinder: (() -> URL?)? = nil
    ) -> [DetectedServer] {
        let home = userEnvironment["HOME"]
        let pathDirs = (userEnvironment["PATH"] ?? "").split(separator: ":").map(String.init)

        var results = catalog.compactMap { entry -> DetectedServer? in
            let probeDirs = entry.extraDirs(home) + pathDirs
            guard let url = firstExecutable(named: entry.binaryName, in: probeDirs, fileManager: fileManager) else {
                return nil
            }
            return DetectedServer(
                languageIDs: entry.languageIDs,
                binaryURL: url,
                launchArguments: entry.launchArguments,
                installHint: entry.installHint,
                displayName: entry.displayName
            )
        }

        let findXcrun = xcrunFinder ?? { defaultXcrunFind(userEnvironment: userEnvironment) }
        if let sourcekitURL = findXcrun() {
            results.append(DetectedServer(
                languageIDs: swiftSpec.languageIDs,
                binaryURL: sourcekitURL,
                launchArguments: [],
                installHint: swiftSpec.installHint,
                displayName: swiftSpec.displayName
            ))
        }

        return results
    }

    private static func firstExecutable(named name: String, in dirs: [String], fileManager: FileManager) -> URL? {
        for dir in dirs {
            let path = (dir as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if fileManager.isExecutableFile(atPath: path),
                fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// Real (non-test) sourcekit-lsp lookup: `xcrun --find sourcekit-lsp`, launched with
    /// the passed-in environment (never the app's own PATH — see the type's doc comment).
    private static func defaultXcrunFind(userEnvironment: [String: String]) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", "sourcekit-lsp"]
        process.environment = userEnvironment

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe() // discard "xcrun: error: ..." noise when absent

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
}
