import Foundation
import LanguageClient
import LanguageServerProtocol
import JSONRPC
import ProcessEnv

/// Lifecycle status of one language's server within a project.
public enum LSPServerStatus: Equatable, Sendable {
    case notInstalled(installHint: String)
    case starting
    case running
    case failed(String)
}

/// The real ChimeHQ handle type callers get back from `server(for:)` — a process-backed,
/// auto-restarting connection. `JSONRPCServerConnection` is the concrete `ServerConnection`
/// LSPProjectManager always wraps; only the `DataChannel` beneath it is swappable (see
/// `LSPChannelFactory` below), so this typealias stays the literal LanguageClient type in
/// both production and tests — no protocol-erasure leaks into the public surface.
public typealias LSPServerHandle = RestartingServer<JSONRPCServerConnection>

/// Resolves the workspace root a language server should be launched with, per the quirks
/// table in the 0.7 LSP plan. Pure/hermetic — no I/O beyond `fileManager.fileExists`, so
/// it's directly unit-testable with temp directories.
enum LSPRootResolver {
    static func resolve(languageID: String, projectRoot: URL, fileManager: FileManager = .default) -> URL {
        switch languageID {
        case "swift":
            return nearestAncestor(containing: "Package.swift", startingAt: projectRoot, fileManager: fileManager) ?? projectRoot
        case "rust":
            return nearestAncestor(containing: "Cargo.toml", startingAt: projectRoot, fileManager: fileManager) ?? projectRoot
        default:
            return projectRoot
        }
    }

    /// Walks upward from `url` (checking `url` itself first), returning the first ancestor
    /// whose directory contains `filename`. `nil` if none does, all the way to `/`.
    ///
    /// Uses `NSString` path manipulation, not `URL.deletingLastPathComponent()`: the URL
    /// version doesn't clamp at the filesystem root — `URL(fileURLWithPath: "/").deletingLastPathComponent()`
    /// keeps appending ".." forever ("/..", "/../..", …), which never satisfies a
    /// `parent == current` fixed-point check and spins indefinitely. `NSString`'s
    /// `deletingLastPathComponent` correctly returns "/" for "/" (verified).
    private static func nearestAncestor(containing filename: String, startingAt url: URL, fileManager: FileManager) -> URL? {
        var current = url.standardizedFileURL.path
        while true {
            if fileManager.fileExists(atPath: (current as NSString).appendingPathComponent(filename)) {
                return URL(fileURLWithPath: current)
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { return nil }
            current = parent
        }
    }
}

/// Builds the `DataChannel` a server connection communicates over. The real implementation
/// (`LocalProcessChannelFactory`) spawns the detected binary as a subprocess. Tests inject a
/// fake in-memory channel instead, so LSPProjectManager's status/bookkeeping/lazy-start logic
/// is exercised without spawning a real language-server process.
///
/// ponytail: this is the seam, not `ServerConnection` itself — `DataChannel` is a plain
/// `{writeHandler, dataSequence}` struct ChimeHQ already designed as swappable (see its
/// README's "custom DataChannel" section), so faking it reuses LanguageClient's own seam
/// rather than inventing a parallel one. `JSONRPCServerConnection` stays identical in both
/// production and tests. Full initialize-handshake byte-level round trips aren't faked here
/// (that's what the live sourcekit-lsp integration test covers) — this seam only proves the
/// manager's own state machine (lazy start, notInstalled, termination handling).
protocol LSPChannelFactory: Sendable {
    func makeChannel(
        detected: DetectedServer,
        environment: [String: String],
        onTerminate: @escaping @Sendable () -> Void
    ) throws -> DataChannel
}

struct LocalProcessChannelFactory: LSPChannelFactory {
    func makeChannel(
        detected: DetectedServer,
        environment: [String: String],
        onTerminate: @escaping @Sendable () -> Void
    ) throws -> DataChannel {
        let parameters = Process.ExecutionParameters(
            path: detected.binaryURL.path,
            arguments: detected.launchArguments,
            environment: environment
        )
        return try DataChannel.localProcessChannel(parameters: parameters, terminationHandler: onTerminate)
    }
}

/// Owns one language server per languageID for a single project, lazily launched on first
/// use. See the 0.7 LSP plan (Task 3) for the design this implements.
@MainActor
public final class LSPProjectManager {
    private let projectRoot: URL
    private let detectedByLanguage: [String: DetectedServer]
    private let userEnvironment: [String: String]
    private let channelFactory: LSPChannelFactory

    private var servers: [String: LSPServerHandle] = [:]
    /// Open-document bookkeeping keyed by URI string. languageID isn't stored here — it's
    /// fixed per server (captured when that server's handle is constructed), and every
    /// public method already receives it from the caller.
    private var openDocuments: [String: (version: Int, text: String)] = [:]
    /// Per-language FIFO chain the actual open/change/close notifications run on. LSP is
    /// stateful and order-dependent (LanguageClient's own README calls a queue "essential"
    /// here) — public methods on this class are synchronous/fire-and-forget, so without this,
    /// three back-to-back calls (e.g. open then immediately close) would race as independent
    /// unstructured Tasks with no ordering guarantee.
    ///
    /// ponytail: unbounded under a hung server — if a language server stops responding
    /// mid-request, every subsequent open/change/close for that language keeps chaining onto
    /// this Task, none of them ever draining. Add a queue-depth cap / timeout if a hung server
    /// turns out to be a real-world occurrence worth guarding against.
    private var pendingWork: [String: Task<Void, Never>] = [:]
    /// Languages `didChangeConfiguration` has already been sent for — sent once per language,
    /// not resent on every `documentOpened`.
    ///
    /// ponytail: not cleared on restart, so a post-crash relaunch (see `handleTermination`)
    /// won't resend it and `pyright` loses its configured `diagnosticMode`. Reset this entry in
    /// `handleTermination` if that turns out to matter in practice.
    private var configuredLanguages: Set<String> = []

    public private(set) var statusByLanguage: [String: LSPServerStatus] = [:]
    public var onStatusChange: (([String: LSPServerStatus]) -> Void)?

    public convenience init(projectRoot: URL, detected: [DetectedServer], userEnvironment: [String: String]) {
        self.init(
            projectRoot: projectRoot,
            detected: detected,
            userEnvironment: userEnvironment,
            channelFactory: LocalProcessChannelFactory()
        )
    }

    /// Test-only seam: substitutes a fake `LSPChannelFactory` so unit tests never spawn a
    /// real process. Not part of the public API.
    init(projectRoot: URL, detected: [DetectedServer], userEnvironment: [String: String], channelFactory: LSPChannelFactory) {
        self.projectRoot = projectRoot
        self.userEnvironment = userEnvironment
        self.channelFactory = channelFactory

        var byLanguage: [String: DetectedServer] = [:]
        for server in detected {
            for languageID in server.languageIDs {
                byLanguage[languageID] = server
            }
        }
        self.detectedByLanguage = byLanguage
    }

    public func server(for languageID: String) -> LSPServerHandle? {
        servers[languageID]
    }

    /// Test-only accessor for the open-document version counter — not part of the public API.
    func openDocumentVersion(for url: URL) -> Int? {
        openDocuments[url.absoluteString]?.version
    }

    public func documentOpened(url: URL, languageID: String, text: String) {
        let uri = url.absoluteString
        openDocuments[uri] = (version: 1, text: text)

        guard let handle = startServerIfNeeded(languageID: languageID) else { return }

        enqueue(languageID: languageID) { [weak self] in
            do {
                _ = try await handle.initializeIfNeeded()
                self?.setStatus(.running, for: languageID)

                if languageID == "python", self?.configuredLanguages.contains(languageID) != true {
                    self?.configuredLanguages.insert(languageID)
                    try await handle.didChangeConfiguration(Self.pyrightConfigurationParams)
                }

                let item = TextDocumentItem(uri: uri, languageId: languageID, version: 1, text: text)
                try await handle.textDocumentDidOpen(DidOpenTextDocumentParams(textDocument: item))
            } catch {
                self?.setStatus(.failed(String(describing: error)), for: languageID)
            }
        }
    }

    public func documentChanged(url: URL, languageID: String, text: String) {
        let uri = url.absoluteString
        guard var doc = openDocuments[uri] else { return }
        doc.version += 1
        doc.text = text
        openDocuments[uri] = doc

        guard let handle = servers[languageID] else { return }

        let version = doc.version
        enqueue(languageID: languageID) { [weak self] in
            do {
                let params = DidChangeTextDocumentParams(
                    uri: uri,
                    version: version,
                    contentChanges: [TextDocumentContentChangeEvent(range: nil, rangeLength: nil, text: text)]
                )
                try await handle.textDocumentDidChange(params)
            } catch {
                self?.setStatus(.failed(String(describing: error)), for: languageID)
            }
        }
    }

    public func documentClosed(url: URL, languageID: String) {
        let uri = url.absoluteString
        openDocuments.removeValue(forKey: uri)

        guard let handle = servers[languageID] else { return }
        enqueue(languageID: languageID) {
            try? await handle.textDocumentDidClose(DidCloseTextDocumentParams(uri: uri))
        }
    }

    public func shutdown() {
        // Cancel every queued-but-not-yet-run notification BEFORE clearing `servers` below —
        // otherwise a Task already holding a strong `handle` reference (captured directly in
        // documentOpened/documentChanged/documentClosed, not looked up via `servers`) would
        // still run after shutdown, find the handle in its lazy `.notStarted`/`.stopped` state,
        // and spawn a brand-new subprocess nobody tracks or ever reaps. `enqueue` checks
        // `Task.isCancelled` before invoking `operation`, so cancelling here is what actually
        // stops that from happening.
        for task in pendingWork.values {
            task.cancel()
        }
        for handle in servers.values {
            Task {
                try? await handle.shutdownAndExit()
            }
        }
        servers.removeAll()
        openDocuments.removeAll()
        pendingWork.removeAll()
    }

    // MARK: - Private

    /// Chains `operation` after whatever's already queued for `languageID`, so open/change/
    /// close notifications for one language's server always run in call order — never
    /// concurrently, never out of order. Skips `operation` entirely if this Task was cancelled
    /// (by `shutdown()`) before its turn came up.
    private func enqueue(languageID: String, _ operation: @escaping @MainActor @Sendable () async -> Void) {
        let previous = pendingWork[languageID]
        pendingWork[languageID] = Task { @MainActor in
            _ = await previous?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    /// Static facts about a known server, used for the install hint when nothing was
    /// detected for `languageID` — `detectedByLanguage` only has entries for servers that
    /// exist on disk, but the banner needs a hint even when one doesn't.
    private static func installHint(for languageID: String) -> String {
        LSPServerDetector.knownServers.first { $0.languageIDs.contains(languageID) }?.installHint ?? ""
    }

    private static let pyrightConfigurationParams = DidChangeConfigurationParams(
        settings: .hash([
            "python": .hash([
                "analysis": .hash([
                    "diagnosticMode": .string("openFilesOnly"),
                ]),
            ]),
        ])
    )

    @discardableResult
    private func startServerIfNeeded(languageID: String) -> LSPServerHandle? {
        if let handle = servers[languageID] { return handle }

        guard let detected = detectedByLanguage[languageID] else {
            setStatus(.notInstalled(installHint: Self.installHint(for: languageID)), for: languageID)
            return nil
        }

        let rootURL = LSPRootResolver.resolve(languageID: languageID, projectRoot: projectRoot)
        let environment = userEnvironment
        let factory = channelFactory

        let serverProvider: LSPServerHandle.ServerProvider = {
            let channel = try factory.makeChannel(detected: detected, environment: environment) {
                Task { @MainActor [weak self] in
                    await self?.handleTermination(languageID: languageID, displayName: detected.displayName)
                }
            }
            return JSONRPCServerConnection(dataChannel: channel)
        }

        let textDocumentItemProvider: LSPServerHandle.TextDocumentItemProvider = { [weak self] uri in
            guard let self, let doc = await self.openDocuments[uri] else {
                throw RestartingServerError.noTextDocumentForURI(uri)
            }
            return TextDocumentItem(uri: uri, languageId: languageID, version: doc.version, text: doc.text)
        }

        let initializeParamsProvider: LSPServerHandle.InitializeParamsProvider = {
            InitializeParams(
                processId: Int(ProcessInfo.processInfo.processIdentifier),
                locale: nil,
                rootPath: rootURL.path,
                rootUri: rootURL.absoluteString,
                initializationOptions: nil,
                capabilities: ClientCapabilities(workspace: nil, textDocument: nil, window: nil, general: nil, experimental: nil),
                trace: nil,
                workspaceFolders: nil
            )
        }

        let configuration = LSPServerHandle.Configuration(
            serverProvider: serverProvider,
            textDocumentItemProvider: textDocumentItemProvider,
            initializeParamsProvider: initializeParamsProvider
        )

        let handle = LSPServerHandle(configuration: configuration)
        servers[languageID] = handle
        setStatus(.starting, for: languageID)
        return handle
    }

    private func setStatus(_ status: LSPServerStatus, for languageID: String) {
        statusByLanguage[languageID] = status
        onStatusChange?(statusByLanguage)
    }

    /// The underlying process exited (crash, or a clean exit after `shutdown()`'s best-effort
    /// exit notification raced with process teardown). `RestartingServer` does NOT relaunch on
    /// its own just because the process died — it only leaves `.running` for good via
    /// `connectionInvalidated()` (which we call here) or `shutdownAndExit()`. Without the call
    /// below, `RestartingServer` stays wedged believing it's still `.running` with a dead
    /// connection underneath, so the next document event hits the dead handle and throws
    /// forever instead of relaunching — the "will restart" status message would be false.
    ///
    /// ponytail: no distinct "crashed, will retry" vs "shut down on purpose" state — the guard
    /// below just makes a termination callback firing after `shutdown()` a no-op (nothing left
    /// in `servers` to look up). Add a distinct status case if the banner ever needs to tell
    /// those two apart.
    private func handleTermination(languageID: String, displayName: String) async {
        guard let handle = servers[languageID] else { return }
        setStatus(.failed("\(displayName) exited — will restart on next document activity"), for: languageID)
        await handle.connectionInvalidated()
    }
}
