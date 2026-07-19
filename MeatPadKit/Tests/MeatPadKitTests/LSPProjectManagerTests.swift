import XCTest
import Foundation
import JSONRPC
import LanguageServerProtocol
@testable import MeatPadKit

// MARK: - LSPRootResolver (pure function)

final class LSPRootResolverTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func touch(_ relativePath: String) throws {
        let url = tempDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    func testSwiftUsesProjectRootWhenItContainsPackageSwift() throws {
        try touch("Package.swift")
        let root = LSPRootResolver.resolve(languageID: "swift", projectRoot: tempDir)
        XCTAssertEqual(root.standardizedFileURL, tempDir.standardizedFileURL)
    }

    func testSwiftWalksUpToAncestorContainingPackageSwift() throws {
        try touch("Package.swift")
        let nested = tempDir.appendingPathComponent("Sources/Sub")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let root = LSPRootResolver.resolve(languageID: "swift", projectRoot: nested)
        XCTAssertEqual(root.standardizedFileURL, tempDir.standardizedFileURL)
    }

    func testSwiftFallsBackToProjectRootWhenNoPackageSwiftFound() {
        let root = LSPRootResolver.resolve(languageID: "swift", projectRoot: tempDir)
        XCTAssertEqual(root.standardizedFileURL, tempDir.standardizedFileURL)
    }

    func testRustWalksUpToAncestorContainingCargoToml() throws {
        try touch("Cargo.toml")
        let nested = tempDir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let root = LSPRootResolver.resolve(languageID: "rust", projectRoot: nested)
        XCTAssertEqual(root.standardizedFileURL, tempDir.standardizedFileURL)
    }

    func testRustFallsBackToProjectRootWhenNoCargoTomlFound() {
        let root = LSPRootResolver.resolve(languageID: "rust", projectRoot: tempDir)
        XCTAssertEqual(root.standardizedFileURL, tempDir.standardizedFileURL)
    }

    func testTypeScriptAndPythonAlwaysUseProjectRoot() throws {
        // Even with a Package.swift/Cargo.toml present, non-swift/rust languages ignore them.
        try touch("Package.swift")
        try touch("Cargo.toml")

        XCTAssertEqual(LSPRootResolver.resolve(languageID: "typescript", projectRoot: tempDir).standardizedFileURL, tempDir.standardizedFileURL)
        XCTAssertEqual(LSPRootResolver.resolve(languageID: "python", projectRoot: tempDir).standardizedFileURL, tempDir.standardizedFileURL)
    }
}

// MARK: - Fake transport

/// Records every channel request and hands back an inert `DataChannel` that never emits
/// data and silently swallows writes — enough to construct a real `RestartingServer` /
/// `JSONRPCServerConnection` stack without a process, so LSPProjectManager's own state
/// machine (lazy start, notInstalled, termination) is exercised for real.
final class SpyChannelFactory: LSPChannelFactory, @unchecked Sendable {
    struct Call {
        let detected: DetectedServer
        let environment: [String: String]
        let onTerminate: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    func makeChannel(
        detected: DetectedServer,
        environment: [String: String],
        onTerminate: @escaping @Sendable () -> Void
    ) throws -> DataChannel {
        lock.lock()
        _calls.append(Call(detected: detected, environment: environment, onTerminate: onTerminate))
        lock.unlock()

        return DataChannel(writeHandler: { _ in }, dataSequence: AsyncStream { _ in })
    }
}

private func makeDetected(_ languageIDs: [String], binaryName: String = "fake-lsp", installHint: String = "install fake-lsp") -> DetectedServer {
    DetectedServer(
        languageIDs: languageIDs,
        binaryURL: URL(fileURLWithPath: "/usr/local/bin/\(binaryName)"),
        launchArguments: [],
        installHint: installHint,
        displayName: binaryName
    )
}

// MARK: - LSPProjectManager

@MainActor
final class LSPProjectManagerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeManager(detected: [DetectedServer], factory: SpyChannelFactory = SpyChannelFactory()) -> LSPProjectManager {
        LSPProjectManager(projectRoot: tempDir, detected: detected, userEnvironment: ["PATH": "/usr/bin"], channelFactory: factory)
    }

    /// `LSPProjectManager`'s public methods are fire-and-forget: `documentOpened` starts the
    /// lazy `RestartingServer`, but the actual channel construction happens inside its
    /// internally-spawned Task (RestartingServer's own laziness — it only calls our
    /// `serverProvider` once something awaits `initializeIfNeeded()`), not synchronously
    /// before `documentOpened` returns. Poll instead of asserting immediately.
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    // MARK: notInstalled path — never launches

    func testDocumentOpenedForUndetectedLanguageSetsNotInstalledStatus() {
        let factory = SpyChannelFactory()
        let manager = makeManager(detected: [], factory: factory)

        manager.documentOpened(url: tempDir.appendingPathComponent("a.rs"), languageID: "rust", text: "fn main() {}")

        XCTAssertEqual(manager.statusByLanguage["rust"], .notInstalled(installHint: "rustup component add rust-analyzer"))
        XCTAssertTrue(factory.calls.isEmpty, "must never attempt to launch a server that isn't detected")
        XCTAssertNil(manager.server(for: "rust"))
    }

    func testNotInstalledFiresOnStatusChangeCallback() {
        let manager = makeManager(detected: [])
        var observed: [String: LSPServerStatus]?
        manager.onStatusChange = { observed = $0 }

        manager.documentOpened(url: tempDir.appendingPathComponent("a.py"), languageID: "python", text: "x = 1")

        XCTAssertEqual(observed?["python"], .notInstalled(installHint: "npm install -g pyright"))
    }

    // MARK: lazy start

    func testServerIsNotStartedUntilFirstDocumentOpened() {
        let factory = SpyChannelFactory()
        let manager = makeManager(detected: [makeDetected(["swift"], binaryName: "sourcekit-lsp")], factory: factory)

        XCTAssertTrue(factory.calls.isEmpty)
        XCTAssertNil(manager.server(for: "swift"))
        XCTAssertNil(manager.statusByLanguage["swift"])
    }

    func testFirstDocumentOpenedLaunchesServerAndSetsStartingStatus() async {
        let factory = SpyChannelFactory()
        let manager = makeManager(detected: [makeDetected(["swift"], binaryName: "sourcekit-lsp")], factory: factory)

        manager.documentOpened(url: tempDir.appendingPathComponent("a.swift"), languageID: "swift", text: "struct A {}")

        // `.starting` is set synchronously by our own bookkeeping, before the underlying
        // RestartingServer lazily calls the channel factory.
        XCTAssertEqual(manager.statusByLanguage["swift"], .starting)
        XCTAssertNotNil(manager.server(for: "swift"))

        await waitUntil { factory.calls.count == 1 }
        XCTAssertEqual(factory.calls.first?.detected.displayName, "sourcekit-lsp")
    }

    func testSecondDocumentOpenedForSameLanguageReusesServerAndDoesNotRelaunch() async {
        let factory = SpyChannelFactory()
        let manager = makeManager(detected: [makeDetected(["swift"], binaryName: "sourcekit-lsp")], factory: factory)

        manager.documentOpened(url: tempDir.appendingPathComponent("a.swift"), languageID: "swift", text: "struct A {}")
        let firstHandle = manager.server(for: "swift")
        manager.documentOpened(url: tempDir.appendingPathComponent("b.swift"), languageID: "swift", text: "struct B {}")

        await waitUntil { !factory.calls.isEmpty }
        // Give a would-be second launch a chance to show up before asserting it never does.
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(factory.calls.count, 1, "must reuse the already-running server for a second document of the same language")
        XCTAssertTrue(manager.server(for: "swift") === firstHandle)
    }

    func testDifferentLanguagesGetIndependentServers() async {
        let factory = SpyChannelFactory()
        let manager = makeManager(
            detected: [makeDetected(["swift"], binaryName: "sourcekit-lsp"), makeDetected(["rust"], binaryName: "rust-analyzer")],
            factory: factory
        )

        manager.documentOpened(url: tempDir.appendingPathComponent("a.swift"), languageID: "swift", text: "")
        manager.documentOpened(url: tempDir.appendingPathComponent("a.rs"), languageID: "rust", text: "")

        XCTAssertEqual(manager.statusByLanguage["swift"], .starting)
        XCTAssertEqual(manager.statusByLanguage["rust"], .starting)

        await waitUntil { factory.calls.count == 2 }
        XCTAssertEqual(factory.calls.count, 2)
    }

    // MARK: environment passthrough

    func testLaunchUsesSuppliedUserEnvironment() async {
        let factory = SpyChannelFactory()
        let manager = LSPProjectManager(
            projectRoot: tempDir,
            detected: [makeDetected(["python"], binaryName: "pyright-langserver")],
            userEnvironment: ["PATH": "/custom/bin", "HOME": "/Users/test"],
            channelFactory: factory
        )

        manager.documentOpened(url: tempDir.appendingPathComponent("a.py"), languageID: "python", text: "")

        await waitUntil { !factory.calls.isEmpty }
        XCTAssertEqual(factory.calls.first?.environment, ["PATH": "/custom/bin", "HOME": "/Users/test"])
    }

    // MARK: termination handling

    func testChannelTerminationMarksServerFailed() async {
        let factory = SpyChannelFactory()
        let manager = makeManager(detected: [makeDetected(["swift"], binaryName: "sourcekit-lsp")], factory: factory)

        manager.documentOpened(url: tempDir.appendingPathComponent("a.swift"), languageID: "swift", text: "")
        XCTAssertEqual(manager.statusByLanguage["swift"], .starting)

        // The channel factory is invoked lazily by RestartingServer, inside the Task
        // `documentOpened` spawned — wait for it before we can grab its `onTerminate`.
        await waitUntil { !factory.calls.isEmpty }

        // Simulate the process exiting, exactly as Process.terminationHandler would invoke it.
        factory.calls.first?.onTerminate()

        // The termination handler hops back to the MainActor via Task; give it a beat.
        await waitUntil {
            if case .failed = manager.statusByLanguage["swift"] { return true }
            return false
        }

        guard case .failed(let message) = manager.statusByLanguage["swift"] else {
            return XCTFail("expected .failed status after termination, got \(String(describing: manager.statusByLanguage["swift"]))")
        }
        XCTAssertTrue(message.contains("sourcekit-lsp"))
    }

    /// Proves `handleTermination` actually calls `RestartingServer.connectionInvalidated()`
    /// (LSP-t3 crash-restart fix). Without that call, `RestartingServer` never leaves its
    /// internal `.running` state after the process dies — the next document event hits the
    /// dead handle and throws forever, the server never relaunches, and the "will restart on
    /// next document activity" status is a lie.
    ///
    /// This deliberately drives the `LSPServerHandle` (`RestartingServer`) returned by
    /// `manager.server(for:)` directly, instead of going through `manager.documentChanged`.
    /// Reason: with `SpyChannelFactory`'s inert fake channel, the `initializeIfNeeded()` call
    /// inside `documentOpened`'s own enqueued operation never completes (its handshake response
    /// never arrives — nothing ever writes to the fake `dataSequence`), which means
    /// `LSPProjectManager`'s own per-language FIFO chain (`pendingWork`, `enqueue`) is
    /// permanently stuck behind it for the rest of the test. That's a limitation of the fake
    /// transport, unrelated to the fix under test — `RestartingServer`'s own semaphore is
    /// already released by the time that handshake await starts, so calling a method on the
    /// handle directly is unaffected and lets the fix be observed for real.
    ///
    /// `connectionInvalidated()` throttles its own restart with a real internal
    /// `Task.sleep(nanoseconds: 5_000_000_000)` before flipping state back to `.notStarted`
    /// (see RestartingServer.swift `connectionInvalidated`) — that's private, unfakeable state
    /// inside the ChimeHQ actor, so the only honest way to observe the fix end-to-end is to
    /// wait past that real throttle for real. This test is intentionally slow (~6s+).
    func testTerminationInvalidatesServerSoALaterChangeActuallyRelaunches() async {
        let factory = SpyChannelFactory()
        let manager = makeManager(detected: [makeDetected(["swift"], binaryName: "sourcekit-lsp")], factory: factory)
        let url = tempDir.appendingPathComponent("a.swift")

        manager.documentOpened(url: url, languageID: "swift", text: "struct A {}")
        await waitUntil { !factory.calls.isEmpty }
        XCTAssertEqual(factory.calls.count, 1)
        let onTerminate = factory.calls.first?.onTerminate
        let handle = try! XCTUnwrap(manager.server(for: "swift"))

        // Simulate the process crashing, exactly as Process.terminationHandler would invoke it.
        onTerminate?()
        await waitUntil {
            if case .failed = manager.statusByLanguage["swift"] { return true }
            return false
        }

        // Wait past RestartingServer's internal 5s connectionInvalidated throttle, then send a
        // change directly on the handle — this is what a real editor keystroke does post-crash.
        // If connectionInvalidated() was never wired, RestartingServer stays wedged in
        // `.running` with the dead handle and this never causes a second launch, no matter how
        // long we wait.
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        let params = DidChangeTextDocumentParams(
            uri: url.absoluteString,
            version: 2,
            contentChanges: [TextDocumentContentChangeEvent(range: nil, rangeLength: nil, text: "struct A { func f() {} }")]
        )
        Task { try? await handle.textDocumentDidChange(params) }

        await waitUntil(timeout: 5) { factory.calls.count == 2 }
        XCTAssertEqual(factory.calls.count, 2, "connectionInvalidated() must be wired so a post-crash change relaunches the server instead of hitting the dead handle forever")
    }

    func testTerminationAfterShutdownIsANoOp() async {
        let factory = SpyChannelFactory()
        let manager = makeManager(detected: [makeDetected(["swift"], binaryName: "sourcekit-lsp")], factory: factory)

        manager.documentOpened(url: tempDir.appendingPathComponent("a.swift"), languageID: "swift", text: "")
        await waitUntil { !factory.calls.isEmpty }
        let onTerminate = factory.calls.first?.onTerminate

        manager.shutdown()
        onTerminate?()

        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertNil(manager.server(for: "swift"))
    }

    // MARK: document bookkeeping / version counters

    func testDocumentChangedIncrementsVersionAcrossMultipleEdits() {
        let factory = SpyChannelFactory()
        let manager = makeManager(detected: [makeDetected(["swift"], binaryName: "sourcekit-lsp")], factory: factory)
        let url = tempDir.appendingPathComponent("a.swift")

        manager.documentOpened(url: url, languageID: "swift", text: "v1")
        XCTAssertEqual(manager.openDocumentVersion(for: url), 1)

        manager.documentChanged(url: url, languageID: "swift", text: "v2")
        XCTAssertEqual(manager.openDocumentVersion(for: url), 2)

        manager.documentChanged(url: url, languageID: "swift", text: "v3")
        XCTAssertEqual(manager.openDocumentVersion(for: url), 3)
    }

    func testDocumentClosedRemovesBookkeepingSoReopenStartsAtVersionOne() {
        let factory = SpyChannelFactory()
        let manager = makeManager(detected: [makeDetected(["swift"], binaryName: "sourcekit-lsp")], factory: factory)
        let url = tempDir.appendingPathComponent("a.swift")

        manager.documentOpened(url: url, languageID: "swift", text: "v1")
        manager.documentChanged(url: url, languageID: "swift", text: "v2")
        manager.documentClosed(url: url, languageID: "swift")

        XCTAssertNil(manager.openDocumentVersion(for: url))

        manager.documentOpened(url: url, languageID: "swift", text: "v1 again")
        XCTAssertEqual(manager.openDocumentVersion(for: url), 1)
    }

    func testDocumentChangedForNeverOpenedURLIsANoOp() {
        let factory = SpyChannelFactory()
        let manager = makeManager(detected: [makeDetected(["swift"], binaryName: "sourcekit-lsp")], factory: factory)
        let url = tempDir.appendingPathComponent("never-opened.swift")

        manager.documentChanged(url: url, languageID: "swift", text: "x")

        XCTAssertNil(manager.openDocumentVersion(for: url))
        XCTAssertTrue(factory.calls.isEmpty, "must not start a server for a change on a document that was never opened")
    }

    // MARK: shutdown

    func testShutdownClearsServersAndOpenDocuments() {
        let factory = SpyChannelFactory()
        let manager = makeManager(detected: [makeDetected(["swift"], binaryName: "sourcekit-lsp")], factory: factory)
        let url = tempDir.appendingPathComponent("a.swift")
        manager.documentOpened(url: url, languageID: "swift", text: "x")

        manager.shutdown()

        XCTAssertNil(manager.server(for: "swift"))
        XCTAssertNil(manager.openDocumentVersion(for: url))
    }

    /// LSP-t3 orphan-process fix: `shutdown()` must cancel queued `pendingWork` before clearing
    /// `servers`, or a change queued right behind a not-yet-run open would still run afterward
    /// — its closure captured `handle` directly (not looked up via `servers`), so clearing the
    /// dict doesn't stop it. That queued operation would then drive the (never-yet-launched)
    /// `RestartingServer` handle from its lazy `.notStarted` state into spawning a brand-new,
    /// completely untracked process nobody reaps.
    ///
    /// `documentOpened` followed immediately by `documentChanged`, with no `await` between
    /// them and `shutdown()`, chains two Tasks for the same language where neither has had a
    /// chance to run its body yet (confirmed by the existing lazy-start tests above, which rely
    /// on the same synchronous-before-first-await guarantee). If `shutdown()`'s cancellation
    /// works, NEITHER task ever calls into the channel factory — not even the original open.
    func testShutdownCancelsPendingQueuedChangeBeforeItCanSpawnAProcess() {
        let factory = SpyChannelFactory()
        let manager = makeManager(detected: [makeDetected(["swift"], binaryName: "sourcekit-lsp")], factory: factory)
        let url = tempDir.appendingPathComponent("a.swift")

        manager.documentOpened(url: url, languageID: "swift", text: "struct A {}")
        manager.documentChanged(url: url, languageID: "swift", text: "struct A { func f() {} }")
        manager.shutdown()

        XCTAssertTrue(factory.calls.isEmpty, "shutdown() must cancel all queued pendingWork so no handle is ever touched and no process is spawned")
        XCTAssertNil(manager.server(for: "swift"))
    }

    // MARK: - Live integration (real sourcekit-lsp, skips cleanly if unavailable)

    /// The one live test the plan calls for: a real `LSPProjectManager` (production
    /// `LocalProcessChannelFactory`, no fakes) against a real `sourcekit-lsp` at a temp SPM
    /// package. Skips — never fails — if sourcekit-lsp isn't detectable or `swift package
    /// init` doesn't work in this environment, so it never breaks CI on a machine without
    /// Xcode's toolchain.
    func testLiveSourceKitLSPReachesRunningStatus() async throws {
        let environment = ProcessInfo.processInfo.environment
        let detected = LSPServerDetector.detect(userEnvironment: environment)
        try XCTSkipUnless(detected.contains { $0.languageIDs.contains("swift") }, "sourcekit-lsp not detected on this machine")

        let packageDir = tempDir.appendingPathComponent("LiveLSPFixture")
        try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)

        let initProcess = Process()
        initProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        initProcess.arguments = ["swift", "package", "init", "--type", "library", "--name", "LiveLSPFixture"]
        initProcess.currentDirectoryURL = packageDir
        initProcess.standardOutput = FileHandle.nullDevice
        initProcess.standardError = FileHandle.nullDevice

        do {
            try initProcess.run()
        } catch {
            throw XCTSkip("couldn't launch `swift package init`: \(error)")
        }
        initProcess.waitUntilExit()
        try XCTSkipUnless(initProcess.terminationStatus == 0, "`swift package init` failed in this environment")

        let sourceFile = FileManager.default.enumerator(at: packageDir.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .first { $0.pathExtension == "swift" }
        try XCTSkipUnless(sourceFile != nil, "`swift package init` didn't produce a .swift source file")
        let fileURL = sourceFile!
        let text = try String(contentsOf: fileURL, encoding: .utf8)

        let manager = LSPProjectManager(projectRoot: packageDir, detected: detected, userEnvironment: environment)
        defer { manager.shutdown() }

        manager.documentOpened(url: fileURL, languageID: "swift", text: text)

        await waitUntil(timeout: 60) {
            if case .running = manager.statusByLanguage["swift"] { return true }
            return false
        }

        XCTAssertEqual(manager.statusByLanguage["swift"], .running)
    }
}
