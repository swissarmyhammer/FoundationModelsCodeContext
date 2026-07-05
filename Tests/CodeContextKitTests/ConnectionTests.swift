import Darwin
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
        try await Self.withConnection(steps: steps) { connection in
            let symbols = try await connection.documentSymbols(in: DocumentURI("file:///a.swift"))

            #expect(symbols.count == 1)
            #expect(symbols.first?.name == "widget")
            #expect(symbols.first?.kind == .function)
        }
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

            guard case let .publishDiagnostics(uri, diagnostics) = notification else {
                Issue.record("expected a publishDiagnostics notification, got \(String(describing: notification))")
                return
            }
            #expect(uri == DocumentURI("file:///c.swift"))
            #expect(diagnostics.count == 1)
            #expect(diagnostics.first?.message == "boom")
            #expect(diagnostics.first?.severity == .error)
        }
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
        #expect(kill(capturedPID, 0) == -1 && errno == ESRCH)

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
        }
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
