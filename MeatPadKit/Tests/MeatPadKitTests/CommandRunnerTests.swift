import XCTest
@testable import MeatPadKit

final class CommandRunnerTests: XCTestCase {

    // MARK: - basic exec

    func testEchoProducesStdoutAndExitZero() async throws {
        let runner = CommandRunner()
        let result = try await runner.run(script: "echo hi", stdin: nil, environment: [:])

        XCTAssertEqual(result.stdout, "hi\n")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
    }

    func testStdinIsPipedToProcess() async throws {
        let runner = CommandRunner()
        let result = try await runner.run(script: "cat", stdin: "round trip", environment: [:])

        XCTAssertEqual(result.stdout, "round trip")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testEnvironmentVariableIsVisibleToScript() async throws {
        let runner = CommandRunner()
        let result = try await runner.run(script: #"printf '%s' "$TM_MODE""#, stdin: nil, environment: ["TM_MODE": "swift"])

        XCTAssertEqual(result.stdout, "swift")
    }

    func testStderrIsCapturedSeparatelyFromStdout() async throws {
        let runner = CommandRunner()
        let result = try await runner.run(script: "echo out; echo err 1>&2", stdin: nil, environment: [:])

        XCTAssertEqual(result.stdout, "out\n")
        XCTAssertEqual(result.stderr, "err\n")
    }

    func testNonZeroExitCodeIsReported() async throws {
        let runner = CommandRunner()
        let result = try await runner.run(script: "exit 7", stdin: nil, environment: [:])

        XCTAssertEqual(result.exitCode, 7)
        XCTAssertFalse(result.timedOut)
    }

    // MARK: - timeout

    func testTimeoutTerminatesProcessQuickly() async throws {
        let runner = CommandRunner()
        let start = Date()

        let result = try await runner.run(script: "sleep 5", stdin: nil, environment: [:], timeout: 0.5)

        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(elapsed, 2.5, "timeout should terminate (or SIGKILL after grace) well before the script's natural 5s sleep")
    }

    // MARK: - large output

    func testLargeStdoutDoesNotDeadlock() async throws {
        let runner = CommandRunner()
        // ~1MB of output: 10000 lines of 100 chars.
        let script = "for i in $(seq 1 10000); do printf '%0100d\\n' 0; done"

        let result = try await runner.run(script: script, stdin: nil, environment: [:], timeout: 10)

        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertGreaterThan(result.stdout.utf8.count, 1_000_000)
    }

    func testStdinToProcessThatNeverReadsItDoesNotCrash() async throws {
        // Reproduces the SIGPIPE crash: `echo hi` exits immediately without ever
        // reading stdin, so writing several MB to it must not raise SIGPIPE and
        // take down the whole test process.
        let runner = CommandRunner()
        let hugeStdin = String(repeating: "x", count: 5_000_000)

        let result = try await runner.run(script: "echo hi", stdin: hugeStdin, environment: [:])

        XCTAssertEqual(result.stdout, "hi\n")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
    }

    func testLargeStdoutAndStderrSimultaneouslyDoesNotDeadlock() async throws {
        // ~300KB on each stream, interleaved, so neither pipe's drain can block
        // waiting on the other.
        let runner = CommandRunner()
        let script = "for i in $(seq 1 3000); do printf '%0100d\\n' 0; printf '%0100d\\n' 1 1>&2; done"

        let result = try await runner.run(script: script, stdin: nil, environment: [:], timeout: 10)

        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertGreaterThanOrEqual(result.stdout.utf8.count, 256_000)
        XCTAssertGreaterThanOrEqual(result.stderr.utf8.count, 256_000)
    }

    // MARK: - cancellation

    func testTaskCancellationKillsProcessAndThrows() async throws {
        let runner = CommandRunner()
        let task = Task {
            try await runner.run(script: "sleep 5", stdin: nil, environment: [:], timeout: 30)
        }
        // Give the process a moment to actually spawn before cancelling.
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    // MARK: - TMEnvironment

    func testTMEnvironmentOmitsNilFieldsEntirely() {
        let ctx = CommandContext()
        let env = TMEnvironment.build(from: ctx)

        XCTAssertNil(env["TM_SELECTED_TEXT"])
        XCTAssertNil(env["TM_FILE_PATH"])
        XCTAssertNil(env["TM_DIRECTORY"])
        XCTAssertNil(env["TM_PROJECT_DIRECTORY"])
        XCTAssertNil(env["TM_LINE_NUMBER"])
        XCTAssertNil(env["TM_COLUMN_NUMBER"])
        XCTAssertNil(env["TM_CURRENT_LINE"])
        XCTAssertNil(env["TM_CURRENT_WORD"])
        XCTAssertNil(env["TM_MODE"])
    }

    func testTMEnvironmentIncludesPopulatedFieldsAndDerivesDirectoryFromFilePath() {
        let ctx = CommandContext(
            selectedText: "hello",
            filePath: "/Users/x/project/file.swift",
            projectDirectory: "/Users/x/project",
            lineNumber: 12,
            columnNumber: 4,
            currentLine: "let x = 1",
            currentWord: "x",
            languageID: "swift"
        )
        let env = TMEnvironment.build(from: ctx)

        XCTAssertEqual(env["TM_SELECTED_TEXT"], "hello")
        XCTAssertEqual(env["TM_FILE_PATH"], "/Users/x/project/file.swift")
        XCTAssertEqual(env["TM_DIRECTORY"], "/Users/x/project")
        XCTAssertEqual(env["TM_PROJECT_DIRECTORY"], "/Users/x/project")
        XCTAssertEqual(env["TM_LINE_NUMBER"], "12")
        XCTAssertEqual(env["TM_COLUMN_NUMBER"], "4")
        XCTAssertEqual(env["TM_CURRENT_LINE"], "let x = 1")
        XCTAssertEqual(env["TM_CURRENT_WORD"], "x")
        XCTAssertEqual(env["TM_MODE"], "swift")
    }

    func testTMEnvironmentMergesOverProcessEnvironment() {
        // A well-known process env var (PATH) must survive the merge, proving TM_*
        // vars are layered on top rather than replacing the base environment.
        let env = TMEnvironment.build(from: CommandContext())
        XCTAssertEqual(env["PATH"], ProcessInfo.processInfo.environment["PATH"])
    }

    // MARK: - TMEnvironment restricted mode

    func testTMEnvironmentRestrictedExcludesArbitraryParentVars() {
        setenv("MEATPAD_TEST_CANARY", "leak-me-not", 1)
        defer { unsetenv("MEATPAD_TEST_CANARY") }

        let unrestricted = TMEnvironment.build(from: CommandContext(), restricted: false)
        XCTAssertEqual(unrestricted["MEATPAD_TEST_CANARY"], "leak-me-not")

        let restricted = TMEnvironment.build(from: CommandContext(), restricted: true)
        XCTAssertNil(restricted["MEATPAD_TEST_CANARY"])
    }

    func testTMEnvironmentRestrictedIncludesTMVarsAndAllowlistFromParentEnv() {
        let ctx = CommandContext(selectedText: "hi", languageID: "swift")
        let restricted = TMEnvironment.build(from: ctx, restricted: true)
        let parent = ProcessInfo.processInfo.environment

        XCTAssertEqual(restricted["TM_SELECTED_TEXT"], "hi")
        XCTAssertEqual(restricted["TM_MODE"], "swift")
        for key in ["PATH", "HOME", "SHELL", "LANG", "TMPDIR"] {
            XCTAssertEqual(restricted[key], parent[key], "allowlisted key \(key) should pass through from parent env when present")
        }
    }

    func testTMEnvironmentRestrictedOmitsAllowlistKeyAbsentFromParentEnv() {
        // If a normally-set allowlist var isn't present in the parent env, restricted
        // mode must not fabricate it (no empty-string entries).
        if ProcessInfo.processInfo.environment["TMPDIR"] == nil {
            let restricted = TMEnvironment.build(from: CommandContext(), restricted: true)
            XCTAssertNil(restricted["TMPDIR"])
        }
    }

    func testTMEnvironmentDefaultIsUnrestricted() {
        // Omitting `restricted` must preserve prior (pre-0.8) behavior: full parent env.
        setenv("MEATPAD_TEST_CANARY_DEFAULT", "present", 1)
        defer { unsetenv("MEATPAD_TEST_CANARY_DEFAULT") }

        let env = TMEnvironment.build(from: CommandContext())
        XCTAssertEqual(env["MEATPAD_TEST_CANARY_DEFAULT"], "present")
    }
}
