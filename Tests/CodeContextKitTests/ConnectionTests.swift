import Foundation
import Testing

@testable import CodeContextKit

/// End-to-end tests for `ProcessLanguageServerConnection`, driven against a
/// real child process: `Support/scripted-lsp-server.swift`, a tiny
/// Content-Length-framed JSON-RPC stub launched the same way a real
/// language server is (`/usr/bin/env swift <script> <script-json>`). See
/// that file's header comment for the scripting DSL.
///
/// Covers the behaviors that only a real process boundary can exercise:
/// request/response over actual pipes, responses arriving out of order,
/// a server-initiated notification surfacing while a request is still
/// in flight, and the injectable-clock timeout path.
///
/// `.serialized`: every test here spawns a real `swift <script>` child process (a full
/// interpreter cold start, not a mock), unlike the rest of the suite. Swift Testing parallelizes
/// tests within a suite by default; letting a dozen-plus of these launch their subprocesses at
/// once was observed (under a loaded machine) to occasionally starve a spawn enough that its
/// pipes closed before the scripted exchange completed, surfacing as a spurious
/// `CodeContextError.notRunning` or `.timeout` even though each test is reliable in isolation.
/// Running them one at a time removes that shared-resource contention without weakening any
/// individual test's coverage.
@Suite(.serialized)
struct ConnectionTests {
    /// The absolute path to the scripted subprocess, resolved relative to this test file so it
    /// doesn't depend on the working directory `swift test` is invoked from.
    private static let scriptedServerPath: String = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Support/scripted-lsp-server.swift")
            .path
    }()

    /// Spawns a `ProcessLanguageServerConnection` against the scripted subprocess.
    /// - Parameters:
    ///   - steps: The subprocess's script, per `scripted-lsp-server.swift`'s DSL.
    ///   - requestTimeout: The per-request timeout to configure the connection with.
    ///   - clock: The clock to configure the connection with.
    private static func makeConnection(
        steps: [[String: Any]],
        requestTimeout: Duration = .seconds(30),
        clock: any Clock<Duration> = ContinuousClock()
    ) throws -> ProcessLanguageServerConnection {
        let scriptData = try JSONSerialization.data(withJSONObject: steps)
        let scriptJSON = String(decoding: scriptData, as: UTF8.self)
        return try ProcessLanguageServerConnection(
            command: "swift",
            arguments: [scriptedServerPath, scriptJSON],
            requestTimeout: requestTimeout,
            clock: clock
        )
    }

    /// A minimal wire-shape `DocumentSymbol` JSON object named `name`.
    private static func documentSymbolJSON(name: String) -> [String: Any] {
        [
            "name": name,
            "kind": 12,
            "range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 1]],
            "selectionRange": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 1]],
        ]
    }

    @Test
    func requestReceivesItsScriptedTypedResponse() async throws {
        let steps: [[String: Any]] = [
            ["action": "read"],
            ["action": "respond", "which": 0, "result": [Self.documentSymbolJSON(name: "widget")]],
        ]
        let connection = try Self.makeConnection(steps: steps)

        let symbols = try await connection.documentSymbols(in: DocumentURI("file:///a.swift"))

        #expect(symbols.count == 1)
        #expect(symbols.first?.name == "widget")
        #expect(symbols.first?.kind == .function)

        await connection.close()
    }

    @Test
    func outOfOrderResponsesAreMatchedByIDNotArrivalOrder() async throws {
        // Two concurrent calls, matched by request identity (`uri`) rather than
        // physical read order: nothing guarantees which of two `async let`
        // calls wins the race to be scheduled onto the connection's actor
        // first, so the script targets each response by the document URI its
        // request named, not by "the first/second request read". The
        // subprocess still answers the file:///b.swift request *before* the
        // file:///a.swift request — the wire's classic out-of-order case —
        // but which physical JSON-RPC id that corresponds to is irrelevant:
        // each concurrent caller must receive its own typed result regardless
        // of which id it was assigned or which response arrived first.
        let steps: [[String: Any]] = [
            ["action": "read"],
            ["action": "read"],
            ["action": "respond", "uri": "file:///b.swift", "result": [Self.documentSymbolJSON(name: "b-result")]],
            ["action": "respond", "uri": "file:///a.swift", "result": [Self.documentSymbolJSON(name: "a-result")]],
        ]
        let connection = try Self.makeConnection(steps: steps)

        async let aCall = connection.documentSymbols(in: DocumentURI("file:///a.swift"))
        async let bCall = connection.documentSymbols(in: DocumentURI("file:///b.swift"))
        let (aResult, bResult) = try await (aCall, bCall)

        #expect(aResult.first?.name == "a-result")
        #expect(bResult.first?.name == "b-result")

        await connection.close()
    }

    @Test
    func serverInitiatedPublishDiagnosticsSurfacesWhileARequestIsInFlight() async throws {
        let diagnosticJSON: [String: Any] = [
            "range": ["start": ["line": 1, "character": 0], "end": ["line": 1, "character": 5]],
            "severity": 1,
            "message": "boom",
        ]
        let steps: [[String: Any]] = [
            ["action": "read"],
            [
                "action": "notify",
                "method": "textDocument/publishDiagnostics",
                "params": ["uri": "file:///c.swift", "diagnostics": [diagnosticJSON]],
            ],
            ["action": "respond", "which": 0, "result": [[String: Any]]()],
        ]
        let connection = try Self.makeConnection(steps: steps)

        async let symbolsCall = connection.documentSymbols(in: DocumentURI("file:///c.swift"))

        var notificationIterator = connection.serverNotifications.makeAsyncIterator()
        let notification = await notificationIterator.next()

        let symbols = try await symbolsCall
        #expect(symbols.isEmpty)

        guard case let .publishDiagnostics(uri, diagnostics) = notification else {
            Issue.record("expected a publishDiagnostics notification, got \(String(describing: notification))")
            await connection.close()
            return
        }
        #expect(uri == DocumentURI("file:///c.swift"))
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.message == "boom")
        #expect(diagnostics.first?.severity == .error)

        await connection.close()
    }

    @Test
    func requestFailsWithTimeoutWhenNoResponseArrives() async throws {
        let steps: [[String: Any]] = [
            ["action": "read"],
            ["action": "hang"],
        ]
        let clock = ManualClock()
        let connection = try Self.makeConnection(steps: steps, requestTimeout: .seconds(30), clock: clock)

        let pendingCall = Task {
            try await connection.documentSymbols(in: DocumentURI("file:///never-answered.swift"))
        }

        // Synchronize with the connection's internal timeout race before advancing the clock,
        // rather than racing a real-time sleep against `clock.sleep(for:)`.
        await clock.waitForWaiter()
        clock.advance(by: .seconds(30))

        do {
            _ = try await pendingCall.value
            Issue.record("expected the request to fail with a timeout")
        } catch let error as CodeContextError {
            guard case .timeout = error else {
                Issue.record("expected .timeout, got \(error)")
                await connection.close()
                return
            }
        }

        await connection.close()
    }

    @Test
    func pidIsPositiveAfterSpawn() async throws {
        let connection = try Self.makeConnection(steps: [["action": "hang"]])
        #expect(connection.pid > 0)
        await connection.close()
    }

    @Test
    func isRunningReflectsProcessLifecycle() async throws {
        let connection = try Self.makeConnection(steps: [["action": "hang"]])
        #expect(await connection.isRunning())
        await connection.close()
    }

    @Test
    func waitUntilExitReturnsOnceTheScriptRunsOut() async throws {
        // An empty script has nothing left to do, so the interpreter process exits on its own —
        // `waitUntilExit()` should return without needing `close()` to kill anything.
        let connection = try Self.makeConnection(steps: [])
        await connection.waitUntilExit()

        // `waitUntilExit()` is tied to stdout hitting EOF; `Process.isRunning` is updated by a
        // separate waitpid-based mechanism that can lag EOF by a few milliseconds. Poll with a
        // bounded budget rather than assuming the two are perfectly synchronized.
        var isRunning = await connection.isRunning()
        var pollsRemaining = 100
        while isRunning, pollsRemaining > 0 {
            try await Task.sleep(for: .milliseconds(10))
            isRunning = await connection.isRunning()
            pollsRemaining -= 1
        }
        #expect(!isRunning)

        await connection.close()
    }

    @Test
    func recentStderrTailCapturesWhatTheServerPrinted() async throws {
        // "hang" after the stderr write keeps the process alive, so this test's timing depends
        // only on the stderr-drain loop noticing the write — not on racing it against process
        // exit (which closes the stdout and stderr pipes independently, in no guaranteed order).
        let steps: [[String: Any]] = [
            ["action": "stderr", "text": "panic: something went wrong"],
            ["action": "hang"],
        ]
        let connection = try Self.makeConnection(steps: steps)

        // The drain loop runs on its own detached task, so the write is captured
        // asynchronously; poll with a bounded budget (60s, matching `LSPDaemon`'s own
        // healthCheckInterval as this codebase's convention for "generous room for real
        // subprocess work") rather than assuming the write has already happened by the time
        // this line runs. A `swift <script>` interpreter cold start is normally well under a
        // second, but measured empirically to stretch past 30s on a machine saturated with
        // concurrently spawned interpreter subprocesses — 60s leaves headroom above that
        // observed worst case.
        var tail = connection.recentStderrTail()
        var pollsRemaining = 6000
        while tail.isEmpty, pollsRemaining > 0 {
            try await Task.sleep(for: .milliseconds(10))
            tail = connection.recentStderrTail()
            pollsRemaining -= 1
        }
        #expect(tail.contains("panic: something went wrong"))

        await connection.close()
    }
}
