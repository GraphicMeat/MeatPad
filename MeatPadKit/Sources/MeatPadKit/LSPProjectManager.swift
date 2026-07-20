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
    /// `forceTerminate`: a fallback the caller invokes if the graceful LSP shutdown+exit
    /// round trip doesn't finish in time. No-op if the process already exited (or, for the
    /// fake factory tests use, if there never was a real process).
    func makeChannel(
        detected: DetectedServer,
        environment: [String: String],
        onTerminate: @escaping @Sendable () -> Void
    ) throws -> (channel: DataChannel, forceTerminate: @Sendable () -> Void)
}

struct LocalProcessChannelFactory: LSPChannelFactory {
    func makeChannel(
        detected: DetectedServer,
        environment: [String: String],
        onTerminate: @escaping @Sendable () -> Void
    ) throws -> (channel: DataChannel, forceTerminate: @Sendable () -> Void) {
        let parameters = Process.ExecutionParameters(
            path: detected.binaryURL.path,
            arguments: detected.launchArguments,
            environment: environment
        )
        // The (channel, process) overload — not the DataChannel-only one — is the only way to
        // keep a handle on the spawned Process. Without it, the only way a server ever exits is
        // if it *chooses* to on receiving the LSP `exit` notification; a server that ignores it
        // (or a shutdown Task that never gets to run before this process exits) leaks forever
        // with no way for us to reap it. LSP-t3.
        let (channel, process) = try DataChannel.localProcessChannel(parameters: parameters, terminationHandler: onTerminate)
        return (channel, { if process.isRunning { process.terminate() } })
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
    /// Per-language force-terminate fallback (SIGTERM via `Process.terminate()`), registered
    /// once the channel factory actually spawns the process. Keyed alongside `servers` so
    /// `shutdown`/`shutdownAndWait` can look up the right one per handle. See LSP-t3.
    private var forceTerminators: [String: @Sendable () -> Void] = [:]
    /// Languages `didChangeConfiguration` has already been sent for — sent once per language,
    /// not resent on every `documentOpened`.
    ///
    /// ponytail: not cleared on restart, so a post-crash relaunch (see `handleTermination`)
    /// won't resend it and `pyright` loses its configured `diagnosticMode`. Reset this entry in
    /// `handleTermination` if that turns out to matter in practice.
    private var configuredLanguages: Set<String> = []

    public private(set) var statusByLanguage: [String: LSPServerStatus] = [:]
    public var onStatusChange: (([String: LSPServerStatus]) -> Void)?
    /// Fires for every `textDocument/publishDiagnostics` notification from any language's
    /// server, across every relaunch. Callers filter by `uri` themselves (this manager has
    /// no notion of which UI is showing which file). Single-slot, same shape as
    /// `onStatusChange` — one app-side owner (`ProjectViewModel`) fans it out further.
    public var onPublishDiagnostics: ((_ uri: DocumentUri, _ diagnostics: [Diagnostic]) -> Void)?
    /// Per-language diagnostics-tap `Task`, keyed and cancelled alongside `pendingWork` in
    /// `snapshotAndClearForShutdown` — see `startDiagnosticsTap`.
    private var diagnosticsTaps: [String: Task<Void, Never>] = [:]

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

    /// Tells `languageID`'s server that file(s) changed on disk while closed — Rename
    /// Symbol's closed-file path (`RenameSymbol.applyToFile`) writes straight to disk,
    /// bypassing `textDocument/didChange` entirely, so the server's own model of these files
    /// (if it caches file contents at all) goes stale until it notices on its own.
    /// `workspace/didChangeWatchedFiles` is the LSP-native way to say "go re-read this".
    ///
    /// Per spec, clients "SHOULD" only send this once a server has *registered* interest via
    /// `client/registerCapability`. Checked what the vendored LanguageClient/
    /// LanguageServerProtocol actually does with that registration
    /// (`ServerCapabilities+Extensions.swift: applyRegistration`): it decodes the
    /// `client/registerCapability` request (so the server does get an empty success reply)
    /// but then, for `workspace/didChangeWatchedFiles` specifically, the switch case is a
    /// bare `break` — the watcher globs are never stored anywhere queryable. There's also no
    /// static `ServerCapabilities` field for it (the spec only defines this as a
    /// dynamic-only registration, unlike e.g. completionProvider). So there is no path,
    /// through this library, to ask "did this server actually register, and for what
    /// globs" — the capability-aware version the plan asked for isn't buildable against
    /// what's vendored.
    ///
    /// Sending unconditionally instead: a server that never registered is spec'd to ignore
    /// file events it doesn't recognize, so this is spec-tolerated, not a violation — and
    /// the alternative (send nothing, ever) guarantees the exact staleness this method
    /// exists to fix. `try?` — best-effort, matches `documentClosed`'s own notification.
    public func filesChangedOnDisk(urls: [URL], languageID: String) {
        guard !urls.isEmpty, let handle = servers[languageID] else { return }
        let changes = urls.map { FileEvent(uri: $0.absoluteString, type: .changed) }
        enqueue(languageID: languageID) {
            try? await handle.workspaceDidChangeWatchedFiles(DidChangeWatchedFilesParams(changes: changes))
        }
    }

    public func shutdown() {
        let (handles, terminators) = snapshotAndClearForShutdown()
        for (languageID, handle) in handles {
            let forceTerminate = terminators[languageID] ?? {}
            Task {
                await Self.shutdownThenForceTerminate(handle: handle, forceTerminate: forceTerminate)
            }
        }
    }

    /// Same effect as `shutdown()`, but awaits every server's graceful-shutdown-then-force-
    /// terminate sequence before returning. `shutdown()` fires those the same way but doesn't
    /// wait — fine for a synchronous app-quit callback, but useless for a test (or any caller)
    /// that needs to know the underlying process is actually gone before it proceeds. LSP-t3.
    public func shutdownAndWait(timeout: TimeInterval = 5) async {
        let (handles, terminators) = snapshotAndClearForShutdown()
        await withTaskGroup(of: Void.self) { group in
            for (languageID, handle) in handles {
                let forceTerminate = terminators[languageID] ?? {}
                group.addTask {
                    await Self.shutdownThenForceTerminate(handle: handle, forceTerminate: forceTerminate, timeout: timeout)
                }
            }
        }
    }

    // MARK: - Private

    /// Cancels every queued-but-not-yet-run notification and clears all bookkeeping, returning
    /// what was live so the caller can drive the actual shutdown. Cancelling `pendingWork`
    /// BEFORE clearing `servers` matters — otherwise a Task already holding a strong `handle`
    /// reference (captured directly in documentOpened/documentChanged/documentClosed, not
    /// looked up via `servers`) would still run after shutdown, find the handle in its lazy
    /// `.notStarted`/`.stopped` state, and spawn a brand-new subprocess nobody tracks or ever
    /// reaps. `enqueue` checks `Task.isCancelled` before invoking `operation`, so cancelling
    /// here is what actually stops that from happening.
    private func snapshotAndClearForShutdown() -> (handles: [String: LSPServerHandle], terminators: [String: @Sendable () -> Void]) {
        for task in pendingWork.values {
            task.cancel()
        }
        for task in diagnosticsTaps.values {
            task.cancel()
        }
        let handles = servers
        let terminators = forceTerminators
        servers.removeAll()
        openDocuments.removeAll()
        pendingWork.removeAll()
        forceTerminators.removeAll()
        diagnosticsTaps.removeAll()
        return (handles, terminators)
    }

    private func registerForceTerminate(_ forceTerminate: @escaping @Sendable () -> Void, for languageID: String) {
        forceTerminators[languageID] = forceTerminate
    }

    /// Sends the graceful LSP shutdown request + exit notification, racing it against
    /// `timeout` so a server that never responds can't hang shutdown forever. Either way,
    /// always finishes by calling `forceTerminate` — a no-op if the process already exited on
    /// its own, a SIGTERM safety net if it's still alive. This is what actually reaps the
    /// process; the graceful path alone depends on the server choosing to honor `exit`.
    ///
    /// The graceful attempt runs as its own detached `Task`, signaled back through an
    /// `AsyncStream` rather than awaited directly — awaiting `handle.shutdownAndExit()`
    /// in-line here would deadlock the deadline itself: its reply is awaited via a checked
    /// continuation (`JSONRPCSession.sendDataRequest`) that outer cancellation does NOT
    /// resolve, so if the server never responds, the direct await would hang forever no
    /// matter what timeout wraps it. `AsyncStream.next()`, unlike `Task.value`, DOES return
    /// promptly on cancellation, so racing it against `Task.sleep` below actually bounds by
    /// `timeout`. If the server really is hung, `forceTerminate()` below kills the process,
    /// which closes its pipe and fails the still-in-flight detached attempt on its own.
    private static func shutdownThenForceTerminate(
        handle: LSPServerHandle,
        forceTerminate: @escaping @Sendable () -> Void,
        timeout: TimeInterval = 5
    ) async {
        let (signal, continuation) = AsyncStream<Void>.makeStream()
        Task {
            try? await handle.shutdownAndExit()
            continuation.yield(())
            continuation.finish()
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                var iterator = signal.makeAsyncIterator()
                _ = await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            }
            await group.next()
            group.cancelAll()
        }
        forceTerminate()
    }

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

        let serverProvider: LSPServerHandle.ServerProvider = { [weak self] in
            // Unwrap once up front (rather than `self?.` below) so the nested `Task`'s own
            // `[weak self]` captures a non-optional `let`, not the optional `weak var` this
            // closure's own capture produces — capturing that var from concurrently-executing
            // code is a Swift 6 error, not just a style nit.
            guard let self else { throw RestartingServerError.serverStopped }
            let (channel, forceTerminate) = try factory.makeChannel(detected: detected, environment: environment) {
                Task { @MainActor [weak self] in
                    await self?.handleTermination(languageID: languageID, displayName: detected.displayName)
                }
            }
            await self.registerForceTerminate(forceTerminate, for: languageID)
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
        startDiagnosticsTap(handle: handle, languageID: languageID)
        return handle
    }

    /// The single reader of `handle.eventSequence` for this language's whole lifetime
    /// (including crash restarts — `RestartingServer` re-taps its own internal stream into
    /// the same outer `eventSequence` on relaunch, so one subscription here covers every
    /// relaunch, not just the first). `AsyncStream` delivers each element to exactly one
    /// consumer, not a broadcast — if every open editor of this language read
    /// `handle.eventSequence` directly, two files of the same language would race for each
    /// `publishDiagnostics` notification instead of both seeing it. Reading it once here and
    /// fanning out through `onPublishDiagnostics` keeps that correct regardless of how many
    /// app-side listeners exist.
    ///
    /// ponytail: this Task keeps `handle` (and so the `RestartingServer` actor) referenced
    /// until either it's cancelled below (in `snapshotAndClearForShutdown`) or the
    /// underlying stream itself finishes — cancellation alone doesn't unblock an in-flight
    /// `for await` suspension, only the next event (or the process's pipe closing, which
    /// `shutdown()`'s `forceTerminate` triggers) does. Bounded to a shutdown-adjacent
    /// transient, not a persistent leak.
    private func startDiagnosticsTap(handle: LSPServerHandle, languageID: String) {
        diagnosticsTaps[languageID] = Task { @MainActor [weak self] in
            for await event in handle.eventSequence {
                guard !Task.isCancelled else { return }
                guard case .notification(.textDocumentPublishDiagnostics(let params)) = event else { continue }
                self?.onPublishDiagnostics?(params.uri, params.diagnostics)
            }
        }
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
