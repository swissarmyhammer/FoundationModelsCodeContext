import Darwin
import Foundation
import ScriptedLSPServerSupport
import Testing

@testable import FoundationModelsCodeContext

/// End-to-end tests for `ProcessLanguageServerConnection`, driven against a
/// real child process: `Support/scripted-lsp-server.swift`, a tiny
/// Content-Length-framed JSON-RPC stub launched the same way a real
/// language server is (`/usr/bin/env swift <script> <script-json>`). The
/// started script is that file joined with the framing code of the library
/// (see `ScriptedLSPServerScript` in `ScriptedLSPServerSupport`). See the header comment of the
/// script for the scripting DSL.
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
    /// The real time between two checks of the state of the subprocess.
    private static let processPollInterval: Duration = .milliseconds(10)

    /// The longest real time that a test waits for the kernel to reap the subprocess after it
    /// exits. The reap occurs some milliseconds after the exit.
    private static let processReapTimeout: Duration = .seconds(1)

    /// The longest real time that a test waits for the stderr text of the subprocess. It is the
    /// `healthCheckInterval` of `LSPDaemon`: a cold start of the `swift <script>` interpreter
    /// took more than 30 seconds on a machine with many other interpreter subprocesses.
    private static let stderrCaptureTimeout: Duration = .seconds(60)

    /// The JSON-RPC id of the first request that a new connection sends. A server request with
    /// this id has the same id as that pending client request. The scripts assert this id on the
    /// first read, thus a change of the first id fails the test and does not hide the collision.
    private static let firstClientRequestID = 0

    /// The JSON-RPC id of the unknown server request. It is not the id of a client request.
    private static let unknownServerRequestID = 41

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
            arguments: [try ScriptedLSPServerScript.path(in: TemporaryItem.root), scriptJSON],
            requestTimeout: requestTimeout,
            clock: clock
        )
    }

    /// Runs `body` against a freshly spawned connection, guaranteeing `close()` runs whether
    /// `body` returns normally or throws.
    ///
    /// Every test in this file used to call `close()` manually as its last line, which meant any
    /// test that threw *before* reaching that line — most commonly a client-side timeout on a
    /// request whose response never showed up — leaked the real child process and its two
    /// detached reader/stderr background loops. Those loops read via a blocking raw `read(2)`
    /// outside actor isolation and never unblock until `close()` kills the process (see
    /// `ProcessLanguageServerConnection.close()`'s doc comment), so each leaked loop permanently
    /// occupies one thread of Swift's fixed-size cooperative concurrency thread pool for the rest
    /// of the test binary's life. It only took the one already-known-flaky timeout in
    /// `requestReceivesItsScriptedTypedResponse()` happening once to eventually starve that pool
    /// and wedge the *entire* binary — not just this suite — well after `ConnectionTests` itself
    /// had finished reporting. This helper is the fix: `close()` now runs on every exit path.
    /// `close()` kills the full process group of the script and waits for the exit of the
    /// script, thus a child process that `swift <script>` starts does not keep the pipes open.
    /// - Parameters:
    ///   - steps: The subprocess's script, per `scripted-lsp-server.swift`'s DSL.
    ///   - requestTimeout: The per-request timeout to configure the connection with.
    ///   - clock: The clock to configure the connection with.
    ///   - body: The test body, given the live connection.
    /// - Returns: `body`'s result.
    /// - Throws: Rethrows whatever `body` throws, after `close()` has already run.
    private static func withConnection<T: Sendable>(
        steps: [[String: Any]],
        requestTimeout: Duration = .seconds(30),
        clock: any Clock<Duration> = ContinuousClock(),
        _ body: (ProcessLanguageServerConnection) async throws -> T
    ) async throws -> T {
        let connection = try makeConnection(steps: steps, requestTimeout: requestTimeout, clock: clock)
        do {
            let result = try await body(connection)
            await connection.close()
            return result
        } catch {
            await connection.close()
            throw error
        }
    }

    /// Retries `operation` once if it throws `CodeContextError.timeout`, giving a spawn-contention
    /// flake (see this suite's doc comment) a second, fully independent subprocess attempt rather
    /// than just waiting longer on a process that may never respond. Only intended for
    /// `requestReceivesItsScriptedTypedResponse()` below, which is the one test this suite's own
    /// doc comment documents as occasionally flaky under load — see that test's comment for why a
    /// bounded retry, rather than a larger timeout, is the right shape of fix here. Any other
    /// error, or a second `.timeout`, propagates: this masks spawn-contention noise, not a real
    /// regression in the exchange itself.
    /// - Parameter operation: The operation to attempt, up to twice.
    /// - Returns: `operation`'s result from whichever attempt succeeded.
    /// - Throws: Whatever the second attempt throws, if the first attempt threw `.timeout` and the
    ///   second attempt also failed; otherwise whatever the first attempt threw, if it wasn't
    ///   `.timeout`.
    private static func withRetryOnSpawnContention<T: Sendable>(
        _ operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch CodeContextError.timeout {
            return try await operation()
        }
    }

    /// Reports whether a process with pid `pid` still exists, per `kill(pid, 0)`: sending signal
    /// `0` delivers no actual signal, only validating that `pid` is a real, still-allocated
    /// process id the caller has permission to signal.
    /// - Parameter pid: The process id to check.
    /// - Returns: `true` if `kill(pid, 0)` reports the pid as present (`0`, or `-1`/`EPERM` for a
    ///   pid owned by another user); `false` once it reports `-1`/`ESRCH` (no such process).
    private static func pidExists(_ pid: Int32) -> Bool {
        errno = 0
        return kill(pid, 0) == 0 || errno != ESRCH
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

    /// A minimal wire-shape `Location` JSON object at `uri`.
    private static func locationJSON(uri: String) -> [String: Any] {
        [
            "uri": uri,
            "range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 1]],
        ]
    }

    /// A minimal wire-shape `CallHierarchyItem` JSON object named `name` at `uri`.
    private static func callHierarchyItemJSON(name: String, uri: String) -> [String: Any] {
        [
            "name": name,
            "kind": 12,
            "uri": uri,
            "range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 1]],
            "selectionRange": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 1]],
        ]
    }

    /// A minimal wire-shape flat `SymbolInformation` JSON object named `name` at `uri`.
    private static func symbolInformationJSON(name: String, uri: String) -> [String: Any] {
        [
            "name": name,
            "kind": 12,
            "location": Self.locationJSON(uri: uri),
        ]
    }

    /// A minimal wire-shape `CodeAction` JSON object titled `title`.
    private static func codeActionJSON(title: String) -> [String: Any] {
        ["title": title]
    }

    @Test
    func requestReceivesItsScriptedTypedResponse() async throws {
        let steps: [[String: Any]] = [
            ["action": "read"],
            ["action": "respond", "which": 0, "result": [Self.documentSymbolJSON(name: "widget")]],
        ]
        // Observed flaky under a loaded machine (2/5 full-suite runs in one filed bug report): a
        // `swift <script>` interpreter cold start can occasionally be starved enough that its
        // pipes close before the scripted exchange completes within the default 30s per-request
        // timeout, surfacing as a spurious `.timeout` even though the scripted exchange itself is
        // trivial. Raising the timeout alone (tried 60s, then 90s) did NOT proportionally reduce
        // the observed failure rate versus the 30s default (roughly 12-13% at both 60s and 90s
        // across repeated full-suite reproduction runs) — evidence this isn't "occasionally a bit
        // slow" so much as "occasionally the response never arrives on this attempt", which no
        // timeout length fixes (`awaitResponse` always surfaces `.timeout` at essentially exactly
        // the configured duration whether the real delay was marginal or unbounded, so the timing
        // alone can't distinguish the two). `withRetryOnSpawnContention` instead gives the
        // exchange a second, fully independent subprocess attempt on a `.timeout` — a much better
        // match for that failure mode than an ever-larger single-attempt budget. This doesn't
        // weaken the assertions below: both attempts run the identical real exchange against a
        // real subprocess, and a second `.timeout` still fails the test.
        let symbols = try await Self.withRetryOnSpawnContention {
            try await Self.withConnection(steps: steps) { connection in
                try await connection.documentSymbols(in: DocumentURI("file:///a.swift"))
            }
        }

        #expect(symbols.count == 1)
        #expect(symbols.first?.name == "widget")
        #expect(symbols.first?.kind == .function)
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
        try await Self.withConnection(steps: steps) { connection in
            async let aCall = connection.documentSymbols(in: DocumentURI("file:///a.swift"))
            async let bCall = connection.documentSymbols(in: DocumentURI("file:///b.swift"))
            let (aResult, bResult) = try await (aCall, bCall)

            #expect(aResult.first?.name == "a-result")
            #expect(bResult.first?.name == "b-result")
        }
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
        try await Self.withConnection(steps: steps) { connection in
            async let symbolsCall = connection.documentSymbols(in: DocumentURI("file:///c.swift"))

            var notificationIterator = connection.serverNotifications.makeAsyncIterator()
            let notification = await notificationIterator.next()

            let symbols = try await symbolsCall
            #expect(symbols.isEmpty)

            guard case .publishDiagnostics(let uri, let diagnostics) = notification else {
                Issue.record("expected a publishDiagnostics notification, got \(String(describing: notification))")
                return
            }
            #expect(uri == DocumentURI("file:///c.swift"))
            #expect(diagnostics.count == 1)
            #expect(diagnostics.first?.message == "boom")
            #expect(diagnostics.first?.severity == .error)
        }
    }

    /// Sends one `documentSymbols` request while the server runs `exchange`, and gives the
    /// symbols that the request gets.
    ///
    /// The script reads the client request (and asserts its id `firstClientRequestID`), runs
    /// `exchange`, and then answers the client request with one symbol named `widget`. When a
    /// read step of `exchange` finds a missing or wrong reply, the script stops, and the request
    /// fails. Thus a test that gets `widget` proves the reply and the true response both.
    /// - Parameter exchange: The server steps between the read and the answer of the request.
    /// - Returns: The symbols that the client request gets.
    private static func documentSymbols(around exchange: [[String: Any]]) async throws -> [DocumentSymbol] {
        let steps: [[String: Any]] =
            [["action": "read", "expectID": Self.firstClientRequestID]]
            + exchange
            + [["action": "respond", "which": 0, "result": [Self.documentSymbolJSON(name: "widget")]]]
        return try await Self.withConnection(steps: steps) { connection in
            try await connection.documentSymbols(in: DocumentURI("file:///a.swift"))
        }
    }

    @Test
    func aServerRequestWithThePendingIDGetsAReplyAndTheRequestGetsItsTrueResponse() async throws {
        // The server asks for configuration with the id of the pending client request. The
        // client must reply to the server, and must not take the server request as the response.
        let symbols = try await Self.documentSymbols(around: [
            [
                "action": "request",
                "id": Self.firstClientRequestID,
                "method": "workspace/configuration",
                "params": ["items": [["section": "python"], ["section": "rust"]]],
            ],
            ["action": "read", "expectID": Self.firstClientRequestID, "expectResult": [NSNull(), NSNull()]],
        ])

        #expect(symbols.map(\.name) == ["widget"])
    }

    @Test
    func aServerRequestWithAStringIDGetsAReplyWithTheSameStringID() async throws {
        let symbols = try await Self.documentSymbols(around: [
            [
                "action": "request",
                "id": "progress-1",
                "method": "window/workDoneProgress/create",
                "params": ["token": "indexing"],
            ],
            ["action": "read", "expectID": "progress-1", "expectResult": NSNull()],
        ])

        #expect(symbols.map(\.name) == ["widget"])
    }

    @Test
    func anUnknownServerRequestGetsAMethodNotFoundError() async throws {
        let symbols = try await Self.documentSymbols(around: [
            ["action": "request", "id": Self.unknownServerRequestID, "method": "custom/unknownMethod", "params": [String: Any]()],
            ["action": "read", "expectID": Self.unknownServerRequestID, "expectErrorCode": TestJSON.methodNotFoundCode],
        ])

        #expect(symbols.map(\.name) == ["widget"])
    }

    @Test
    func requestFailsWithTimeoutWhenNoResponseArrives() async throws {
        let steps: [[String: Any]] = [
            ["action": "read"],
            ["action": "hang"],
        ]
        let clock = ManualClock()
        try await Self.withConnection(steps: steps, requestTimeout: .seconds(30), clock: clock) { connection in
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
                    return
                }
            }
        }
    }

    @Test
    func aRequestTimeoutThatPropagatesUncaughtStillClosesTheConnectionAndReapsTheProcess() async throws {
        // Exercises the exact shape that used to leak: a request throws `.timeout` and that error
        // propagates *uncaught* out of the test body, rather than being caught locally the way
        // `requestFailsWithTimeoutWhenNoResponseArrives()` above does. Before `withConnection`
        // existed, every test manually called `close()` as its last line, so a throw before
        // reaching that line skipped it entirely — leaking the real child process and its two
        // detached reader/stderr loops, which block in a raw `read(2)` outside actor isolation and
        // never unblock until `close()` kills the process. Enough of those leaking (it only took
        // the one already-known-flaky timeout in `requestReceivesItsScriptedTypedResponse()`,
        // once) exhausts Swift's fixed-size cooperative thread pool and wedges the *entire* test
        // binary, not just this suite — the incident that prompted this test.
        let clock = ManualClock()
        var capturedPID: Int32 = -1

        await #expect(throws: CodeContextError.self) {
            try await Self.withConnection(steps: [["action": "read"], ["action": "hang"]], requestTimeout: .seconds(5), clock: clock) { connection in
                capturedPID = connection.pid
                let pendingCall = Task {
                    try await connection.documentSymbols(in: DocumentURI("file:///never.swift"))
                }
                await clock.waitForWaiter()
                clock.advance(by: .seconds(5))
                _ = try await pendingCall.value
            }
        }

        #expect(capturedPID > 0)
        // `withConnection`'s catch branch must have run `close()` despite the closure throwing —
        // if it hadn't, `capturedPID` would still identify a live process. `kill(pid, 0)` sends no
        // signal; it only reports whether a process with that pid still exists.
        //
        // `close()` waits for the reap of the process, thus the pid is gone when `close()`
        // returns. The test still polls with a bounded budget, because a cancel of the task of
        // `close()` lets `close()` return after `SIGKILL` and before the reap.
        let pid = capturedPID
        let isReaped = try await waitUntil(timeout: Self.processReapTimeout, pollInterval: Self.processPollInterval) {
            !Self.pidExists(pid)
        }
        #expect(isReaped)

        // If the above had leaked its reader/stderr threads, they'd permanently occupy slots in
        // Swift's cooperative thread pool; spawning, running, and tearing down one more connection
        // here proves the binary is still making normal progress afterward.
        try await Self.withConnection(steps: []) { connection in
            await connection.waitUntilExit()
        }
    }

    @Test
    func pidIsPositiveAfterSpawn() async throws {
        try await Self.withConnection(steps: [["action": "hang"]]) { connection in
            #expect(connection.pid > 0)
        }
    }

    @Test
    func isRunningReflectsProcessLifecycle() async throws {
        try await Self.withConnection(steps: [["action": "hang"]]) { connection in
            #expect(await connection.isRunning())
        }
    }

    @Test
    func waitUntilExitReturnsOnceTheScriptRunsOut() async throws {
        // An empty script has nothing left to do, so the interpreter process exits on its own —
        // `waitUntilExit()` should return without needing `close()` to kill anything.
        try await Self.withConnection(steps: []) { connection in
            await connection.waitUntilExit()

            // `waitUntilExit()` and `isRunning()` both read the reap of the process, thus
            // `isRunning()` is `false` here. The bounded poll keeps the test safe if a later
            // change gives the two different sources again.
            let hasStopped = try await waitUntil(timeout: Self.processReapTimeout, pollInterval: Self.processPollInterval) {
                await !connection.isRunning()
            }
            #expect(hasStopped)
        }
    }

    @Test
    func aNegativeContentLengthFailsThePendingRequestAndStopsTheServer() async throws {
        // A negative length tells nothing about where the body stops, thus the stream is out of
        // step. The connection must not crash and must not wait for a body that does not come:
        // it fails the pending request at once and stops the server. The health check of the
        // daemon then finds a dead process and starts the server again.
        let steps: [[String: Any]] = [
            ["action": "read"],
            ["action": "writeRaw", "text": "Content-Length: -5\r\n\r\n"],
            ["action": "hang"],
        ]
        try await Self.withConnection(steps: steps) { connection in
            let error = await #expect(throws: CodeContextError.self) {
                try await connection.documentSymbols(in: DocumentURI("file:///a.swift"))
            }
            #expect(error?.caseName == "notRunning")

            let hasStopped = try await waitUntil(timeout: Self.processReapTimeout, pollInterval: Self.processPollInterval) {
                await !connection.isRunning()
            }
            #expect(hasStopped)
        }
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
        try await Self.withConnection(steps: steps) { connection in
            // The drain loop runs on its own detached task, so the write is captured
            // asynchronously. The test waits at most `stderrCaptureTimeout` for the write, and
            // does not assume that the write occurred before this line.
            try await waitUntil(timeout: Self.stderrCaptureTimeout, pollInterval: Self.processPollInterval) {
                !connection.recentStderrTail().isEmpty
            }
            #expect(connection.recentStderrTail().contains("panic: something went wrong"))
        }
    }

    // MARK: - initialize through the production connection factory

    /// Starts the scripted subprocess through `LSPDaemon.processConnectionFactory()` with a spec
    /// that holds `initializationOptions`, and sends `initialize` on the connection. The script
    /// stops before it answers when the `initializationOptions` of the request is not
    /// `expected`, thus the request then fails.
    /// - Parameters:
    ///   - initializationOptions: The options of the spec.
    ///   - expected: The `initializationOptions` value that the request must hold, as
    ///     `JSONSerialization` reads it. `NSNull()` accepts an absent field.
    private static func initializeThroughTheProductionFactory(
        initializationOptions: JSONValue?,
        expected: Any
    ) async throws {
        let steps: [[String: Any]] = [
            ["action": "read", "expectMethod": "initialize", "expectInitializationOptions": expected],
            ["action": "respond", "which": 0, "result": ["capabilities": [String: Any]()]],
        ]
        let scriptJSON = String(decoding: try JSONSerialization.data(withJSONObject: steps), as: UTF8.self)
        let spec = ServerSpec(
            command: "swift",
            arguments: [try ScriptedLSPServerScript.path(in: TemporaryItem.root), scriptJSON],
            languageIDs: ["swift"],
            installHint: "the scripted server needs no install",
            initializationOptions: initializationOptions
        )
        let factory = LSPDaemon<ProcessLanguageServerConnection>.processConnectionFactory()
        let handle = try await factory(spec, TemporaryItem.root)
        do {
            _ = try await handle.connection.initialize(rootURI: DocumentURI("file:///repo"))
            await handle.terminate()
        } catch {
            await handle.terminate()
            throw error
        }
    }

    @Test
    func initializeSendsTheInitializationOptionsOfTheSpec() async throws {
        let options: JSONValue = .object(["cargo": .object(["features": .string("all")])])

        try await Self.initializeThroughTheProductionFactory(
            initializationOptions: options,
            expected: ["cargo": ["features": "all"]]
        )
    }

    @Test
    func initializeSendsNoInitializationOptionsWhenTheSpecHasNone() async throws {
        try await Self.initializeThroughTheProductionFactory(initializationOptions: nil, expected: NSNull())
    }

    // MARK: - Refactored helper call sites (notifyEmpty, notifyTextDocument,
    // positionParams/requestAtPosition, arrayRequest, locationsRequest)

    @Test
    func initializedAndExitSendNoPayloadNotifications() async throws {
        // `initialized()` and `exit()` both route through `notifyEmpty`, the shape shared
        // by every fire-and-forget notification with no params. Neither has a response to
        // assert on directly, so the script instead asserts on the wire method name as it
        // reads each one (exiting with a stderr message on a mismatch, which would then
        // surface as a request timeout/failure below). A canary `documentSymbols` request
        // after both notifications proves neither one corrupted the Content-Length-framed
        // byte stream — a malformed frame would desync every subsequent read, including
        // this one.
        let steps: [[String: Any]] = [
            ["action": "read", "expectMethod": "initialized"],
            ["action": "read", "expectMethod": "exit"],
            ["action": "read"],
            ["action": "respond", "which": 2, "result": [Self.documentSymbolJSON(name: "after-notifications")]],
        ]
        try await Self.withConnection(steps: steps) { connection in
            try await connection.initialized()
            try await connection.exit()

            let symbols = try await connection.documentSymbols(in: DocumentURI("file:///a.swift"))
            #expect(symbols.first?.name == "after-notifications")
        }
    }

    @Test
    func didSaveAndDidCloseSendTextDocumentNotifications() async throws {
        // `didSave(uri:)` and `didClose(uri:)` both route through `notifyTextDocument`, the
        // shape shared by every `textDocument/*` notification whose params wrap a bare
        // `TextDocumentIdentifier`. As above, the script asserts on both the method name and
        // the carried `uri` as it reads each notification, and a canary request afterward
        // proves the stream is still framed correctly.
        let steps: [[String: Any]] = [
            ["action": "read", "expectMethod": "textDocument/didSave", "expectURI": "file:///saved.swift"],
            ["action": "read", "expectMethod": "textDocument/didClose", "expectURI": "file:///closed.swift"],
            ["action": "read"],
            ["action": "respond", "which": 2, "result": [Self.documentSymbolJSON(name: "after-textdocument-notifications")]],
        ]
        try await Self.withConnection(steps: steps) { connection in
            try await connection.didSave(uri: DocumentURI("file:///saved.swift"))
            try await connection.didClose(uri: DocumentURI("file:///closed.swift"))

            let symbols = try await connection.documentSymbols(in: DocumentURI("file:///a.swift"))
            #expect(symbols.first?.name == "after-textdocument-notifications")
        }
    }

    @Test
    func hoverReturnsAPositionKeyedSingleResult() async throws {
        // `hover(in:at:)` routes through `requestAtPosition`, which sends `positionParams`
        // and decodes the result directly (no array or `LocationsResult` wrapping).
        let steps: [[String: Any]] = [
            ["action": "read"],
            [
                "action": "respond", "which": 0,
                "result": [
                    "contents": ["kind": "markdown", "value": "widget docs"],
                    "range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 6]],
                ],
            ],
        ]
        try await Self.withConnection(steps: steps) { connection in
            let hover = try await connection.hover(in: DocumentURI("file:///a.swift"), at: Position(line: 0, character: 3))
            #expect(hover?.contents == "widget docs")
            #expect(hover?.range?.start.character == 0)
        }
    }

    @Test
    func prepareRenameReturnsAPositionKeyedSingleResult() async throws {
        // `prepareRename(in:at:)` also routes through `requestAtPosition`, sharing the same
        // shape as `hover` above but with a different result type.
        let steps: [[String: Any]] = [
            ["action": "read"],
            [
                "action": "respond", "which": 0,
                "result": [
                    "range": ["start": ["line": 1, "character": 0], "end": ["line": 1, "character": 5]],
                    "placeholder": "widget",
                ],
            ],
        ]
        try await Self.withConnection(steps: steps) { connection in
            let result = try await connection.prepareRename(in: DocumentURI("file:///a.swift"), at: Position(line: 1, character: 2))
            #expect(result.placeholder == "widget")
            #expect(result.range?.start.line == 1)
        }
    }

    @Test
    func prepareCallHierarchyReturnsAPositionKeyedArrayResult() async throws {
        // `prepareCallHierarchy(in:at:)` routes through `arrayRequest`, using
        // `positionParams` for its params — the position-keyed array-request shape,
        // distinct from `requestAtPosition`'s single-result shape above.
        let steps: [[String: Any]] = [
            ["action": "read"],
            ["action": "respond", "which": 0, "result": [Self.callHierarchyItemJSON(name: "widget", uri: "file:///a.swift")]],
        ]
        try await Self.withConnection(steps: steps) { connection in
            let items = try await connection.prepareCallHierarchy(in: DocumentURI("file:///a.swift"), at: Position(line: 0, character: 0))
            #expect(items.count == 1)
            #expect(items.first?.name == "widget")
        }
    }

    @Test
    func outgoingCallsAndIncomingCallsNormalizeANullResultToAnEmptyArray() async throws {
        // `outgoingCalls(of:)`/`incomingCalls(of:)` also route through `arrayRequest`, but
        // with non-position (`CallHierarchyCallsParams`) params, and here a scripted `null`
        // result exercises `arrayRequest`'s optional-array normalization directly, rather
        // than an already-empty array indistinguishable from "the server sent no results".
        let item = CallHierarchyItem(
            name: "widget",
            kind: .function,
            detail: nil,
            uri: DocumentURI("file:///a.swift"),
            range: LSPRange(start: Position(line: 0, character: 0), end: Position(line: 0, character: 1)),
            selectionRange: LSPRange(start: Position(line: 0, character: 0), end: Position(line: 0, character: 1))
        )
        // `outgoingCalls`/`incomingCalls` are awaited sequentially below (not concurrently, unlike
        // `outOfOrderResponsesAreMatchedByIDNotArrivalOrder()` above), so the second request is only
        // sent once the first response arrives — the script must respond to each in turn rather
        // than reading both up front, or its second "read" would block forever waiting for a
        // request the client won't send until this script unblocks its first `await` by responding.
        let steps: [[String: Any]] = [
            ["action": "read"],
            ["action": "respond", "which": 0, "result": NSNull()],
            ["action": "read"],
            ["action": "respond", "which": 1, "result": NSNull()],
        ]
        try await Self.withConnection(steps: steps) { connection in
            let outgoing = try await connection.outgoingCalls(of: item)
            let incoming = try await connection.incomingCalls(of: item)
            #expect(outgoing.isEmpty)
            #expect(incoming.isEmpty)
        }
    }

    @Test
    func codeActionsAndWorkspaceSymbolsReturnNonPositionArrayResults() async throws {
        // `codeActions(in:range:diagnostics:only:)` and `workspaceSymbols(query:)` route
        // through `arrayRequest` with params that carry no cursor position at all — the
        // non-position array-request shape, distinct from `prepareCallHierarchy` above.
        // Awaited sequentially, so (as in `outgoingCallsAndIncomingCallsNormalizeANullResultToAnEmptyArray()`
        // above) the script must respond to each in turn rather than reading both up front.
        let steps: [[String: Any]] = [
            ["action": "read"],
            ["action": "respond", "which": 0, "result": [Self.codeActionJSON(title: "Fix it")]],
            ["action": "read"],
            ["action": "respond", "which": 1, "result": [Self.symbolInformationJSON(name: "widget", uri: "file:///a.swift")]],
        ]
        try await Self.withConnection(steps: steps) { connection in
            let actions = try await connection.codeActions(
                in: DocumentURI("file:///a.swift"),
                range: LSPRange(start: Position(line: 0, character: 0), end: Position(line: 0, character: 1)),
                diagnostics: [],
                only: nil
            )
            let symbols = try await connection.workspaceSymbols(query: "widget")

            #expect(actions.first?.title == "Fix it")
            #expect(symbols.first?.name == "widget")
        }
    }

    @Test
    func referencesReturnsALocationsResultWrappedResult() async throws {
        // `references(in:at:includeDeclaration:)` calls `locationsRequest` directly (its
        // params additionally carry `ReferenceContext`, unlike `positionRequest`'s callers
        // below), unwrapping the scripted array through `LocationsResult`.
        let steps: [[String: Any]] = [
            ["action": "read"],
            ["action": "respond", "which": 0, "result": [Self.locationJSON(uri: "file:///a.swift"), Self.locationJSON(uri: "file:///b.swift")]],
        ]
        try await Self.withConnection(steps: steps) { connection in
            let locations = try await connection.references(
                in: DocumentURI("file:///a.swift"),
                at: Position(line: 0, character: 0),
                includeDeclaration: true
            )
            #expect(locations.map(\.uri.value) == ["file:///a.swift", "file:///b.swift"])
        }
    }

    @Test
    func definitionTypeDefinitionAndImplementationsReturnLocationsResultWrappedResults() async throws {
        // `definition`/`typeDefinition`/`implementations` all route through `positionRequest`
        // (which builds `positionParams` and delegates to `locationsRequest`, same as
        // `references` above but without the extra context). Scripting a bare `Location`
        // object, an array, and a `null` result across the three exercises all three shapes
        // `LocationsResult`'s decoder normalizes. Awaited sequentially, so (as in the
        // `arrayRequest` tests above) the script must respond to each in turn rather than
        // reading all three requests up front.
        let steps: [[String: Any]] = [
            ["action": "read"],
            ["action": "respond", "which": 0, "result": Self.locationJSON(uri: "file:///def.swift")],
            ["action": "read"],
            ["action": "respond", "which": 1, "result": [Self.locationJSON(uri: "file:///type-def.swift")]],
            ["action": "read"],
            ["action": "respond", "which": 2, "result": NSNull()],
        ]
        try await Self.withConnection(steps: steps) { connection in
            let definitions = try await connection.definition(in: DocumentURI("file:///a.swift"), at: Position(line: 0, character: 0))
            let typeDefinitions = try await connection.typeDefinition(in: DocumentURI("file:///a.swift"), at: Position(line: 0, character: 0))
            let implementations = try await connection.implementations(in: DocumentURI("file:///a.swift"), at: Position(line: 0, character: 0))

            #expect(definitions.map(\.uri.value) == ["file:///def.swift"])
            #expect(typeDefinitions.map(\.uri.value) == ["file:///type-def.swift"])
            #expect(implementations.isEmpty)
        }
    }
}
