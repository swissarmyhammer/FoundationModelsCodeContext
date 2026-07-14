import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// Tests for `LSPDaemon`, driven entirely against `FakeLanguageServerConnection` and a
/// `ManualClock` so no real subprocess is ever spawned and no real wall-clock time is ever
/// waited.
///
/// Covers the lifecycle described in plan.md's LSP subsystem: PATH lookup (`.notFound`),
/// spawn + handshake bounded by `spec.startupTimeout`, health-check-driven crash detection
/// (tearing down the session's open-document set), restart with exponential backoff (giving up
/// after 5 consecutive failures), `forceRestart()` resetting the counter, and graceful shutdown
/// bounded by a grace period with a force-kill fallback.
struct LSPDaemonTests {
    // MARK: - Fixtures

    /// Builds a `ServerSpec` for tests. `command` defaults to `"true"` — a real, near-instant
    /// Unix utility — so `LSPDaemon`'s `$PATH` lookup (which isn't mockable; it's a genuine
    /// filesystem check) succeeds on every test runner without actually being spawned: the
    /// connection factory always substitutes a `FakeLanguageServerConnection` before any real
    /// process would be launched.
    private static func serverSpec(
        command: String = "true",
        startupTimeout: Duration = .seconds(5),
        installHint: String = "install the fake LSP server"
    ) -> ServerSpec {
        ServerSpec(command: command, languageIDs: ["fake"], startupTimeout: startupTimeout, installHint: installHint)
    }

    /// A workspace root fixture; `LSPDaemon` only uses this to build the `initialize` request's
    /// `rootUri`, so no real directory needs to exist on disk.
    private static let workspaceRoot = URL(fileURLWithPath: "/tmp/lsp-daemon-tests")

    /// An error a scripted `FakeLanguageServerConnection` throws to simulate a handshake that
    /// the server actively rejects (distinct from a timeout, which never throws from the fake at
    /// all — the clock's timeout branch wins the race instead).
    private struct SimulatedHandshakeFailure: Error {}

    // `Box`, `ProcessState`, and `fakeConnectionFactory` live in `Support/FakeDaemonProcess.swift`,
    // shared with `LspSupervisorTests`.

    // MARK: - Initial state

    @Test
    func initialStateIsNotStarted() async {
        let processState = ProcessState()
        let daemon = LSPDaemon<FakeLanguageServerConnection>(
            spec: Self.serverSpec(),
            workspaceRoot: Self.workspaceRoot,
            clock: ManualClock(),
            connectionFactory: fakeConnectionFactory(pid: 1, processState: processState)
        )
        let state = await daemon.state()
        #expect(state == .notStarted)
        let session = await daemon.session()
        #expect(session == nil)
    }

    // MARK: - start()

    @Test
    func startFailsWithNotFoundWhenBinaryMissing() async {
        let daemon = LSPDaemon<FakeLanguageServerConnection>(
            spec: Self.serverSpec(command: "nonexistent-lsp-binary-abc123xyz"),
            workspaceRoot: Self.workspaceRoot,
            clock: ManualClock(),
            connectionFactory: { _, _ in
                Issue.record("the connection factory must not run when the binary isn't on PATH")
                throw SimulatedHandshakeFailure()
            }
        )

        await #expect(throws: CodeContextError.self) {
            try await daemon.start()
        }
        let state = await daemon.state()
        #expect(state == .notFound)
    }

    @Test
    func startSucceedsAndReachesRunningWithReportedPid() async throws {
        let processState = ProcessState()
        let daemon = LSPDaemon<FakeLanguageServerConnection>(
            spec: Self.serverSpec(),
            workspaceRoot: Self.workspaceRoot,
            clock: ManualClock(),
            connectionFactory: fakeConnectionFactory(pid: 4242, processState: processState)
        )

        try await daemon.start()

        let state = await daemon.state()
        #expect(state == .running(pid: 4242))
        let session = await daemon.session()
        #expect(session != nil)
    }

    @Test
    func handshakeTimeoutKillsTheConnectionAndCapturesStderrTail() async throws {
        let clock = ManualClock()
        let terminateCalls = ProcessState()
        // A connection whose `initialize` never returns, so the daemon's handshake timeout is
        // the only way `performHandshake` can complete.
        let hangingConnection = HangingInitializeConnection()
        let spec = Self.serverSpec(startupTimeout: .seconds(5))
        let daemon = LSPDaemon<HangingInitializeConnection>(
            spec: spec,
            workspaceRoot: Self.workspaceRoot,
            clock: clock,
            connectionFactory: { _, _ in
                ConnectionHandle(
                    connection: hangingConnection,
                    pid: 9999,
                    isAlive: { true },
                    waitForExit: {},
                    terminate: { await terminateCalls.markTerminated() },
                    stderrTail: { "server printed: boom" }
                )
            }
        )

        let startTask = Task { try? await daemon.start() }
        await clock.waitForWaiter()
        clock.advance(by: .seconds(5))
        _ = await startTask.value

        let state = await daemon.state()
        guard case let .failed(reason, attempts) = state else {
            Issue.record("expected .failed, got \(state)")
            return
        }
        #expect(attempts == 1)
        #expect(reason.contains("boom"), "expected the stderr tail to be folded into the failure reason, got: \(reason)")
        let terminations = await terminateCalls.terminateCount
        #expect(terminations == 1)
    }

    // MARK: - healthCheck()

    @Test
    func healthCheckDetectsCrashAndResetsSessionDocuments() async throws {
        let processState = ProcessState()
        let daemon = LSPDaemon<FakeLanguageServerConnection>(
            spec: Self.serverSpec(),
            workspaceRoot: Self.workspaceRoot,
            clock: ManualClock(),
            connectionFactory: fakeConnectionFactory(pid: 1, processState: processState)
        )
        try await daemon.start()

        let session = try #require(await daemon.session())
        let uri = DocumentURI("file:///tmp/a.fake")
        try await session.syncOpen(uri: uri, text: "hello")
        var docs = await session.openDocuments()
        #expect(docs[uri] != nil, "document should be open before the crash")

        await processState.setAlive(false)
        let stillAlive = await daemon.healthCheck()
        #expect(!stillAlive)

        docs = await session.openDocuments()
        #expect(docs.isEmpty, "resetDocuments() must have been called on the session after the crash")

        let state = await daemon.state()
        guard case let .failed(_, attempts) = state else {
            Issue.record("expected .failed, got \(state)")
            return
        }
        #expect(attempts == 1)
    }

    @Test
    func healthCheckReturnsFalseWhenNotRunning() async {
        let processState = ProcessState()
        let daemon = LSPDaemon<FakeLanguageServerConnection>(
            spec: Self.serverSpec(),
            workspaceRoot: Self.workspaceRoot,
            clock: ManualClock(),
            connectionFactory: fakeConnectionFactory(pid: 1, processState: processState)
        )
        let alive = await daemon.healthCheck()
        #expect(!alive)
        let state = await daemon.state()
        #expect(state == .notStarted, "a health check with nothing running must not itself record a failure")
    }

    // MARK: - backoffDuration(forAttempt:)

    @Test
    func backoffDurationMatchesTheDoublingSequenceCappedAtSixty() {
        #expect(LSPDaemon<FakeLanguageServerConnection>.backoffDuration(forAttempt: 0) == .seconds(1))
        #expect(LSPDaemon<FakeLanguageServerConnection>.backoffDuration(forAttempt: 1) == .seconds(2))
        #expect(LSPDaemon<FakeLanguageServerConnection>.backoffDuration(forAttempt: 2) == .seconds(4))
        #expect(LSPDaemon<FakeLanguageServerConnection>.backoffDuration(forAttempt: 3) == .seconds(8))
        #expect(LSPDaemon<FakeLanguageServerConnection>.backoffDuration(forAttempt: 4) == .seconds(16))
        #expect(LSPDaemon<FakeLanguageServerConnection>.backoffDuration(forAttempt: 5) == .seconds(32))
        #expect(LSPDaemon<FakeLanguageServerConnection>.backoffDuration(forAttempt: 6) == .seconds(60))
        #expect(LSPDaemon<FakeLanguageServerConnection>.backoffDuration(forAttempt: 7) == .seconds(60))
        #expect(LSPDaemon<FakeLanguageServerConnection>.backoffDuration(forAttempt: 100) == .seconds(60))
    }

    // MARK: - restartWithBackoff()

    @Test
    func restartWithBackoffSequenceGivesUpAfterFiveConsecutiveFailures() async throws {
        let clock = ManualClock()
        let processState = ProcessState()
        let shouldFailHandshake = Box(false)

        let daemon = LSPDaemon<FakeLanguageServerConnection>(
            spec: Self.serverSpec(),
            workspaceRoot: Self.workspaceRoot,
            clock: clock,
            connectionFactory: fakeConnectionFactory(pid: 1, processState: processState) { connection in
                if await shouldFailHandshake.value {
                    await connection.setInitializeResult(to: .failure(SimulatedHandshakeFailure()))
                }
            }
        )

        // Establish the initial crash: a healthy start, then a detected exit.
        try await daemon.start()
        await shouldFailHandshake.set(true)
        await processState.setAlive(false)
        _ = await daemon.healthCheck()
        var state = await daemon.state()
        guard case let .failed(_, initialAttempts) = state else {
            Issue.record("expected .failed after the crash, got \(state)")
            return
        }
        #expect(initialAttempts == 1)

        // Every restart attempt below fails its handshake (scripted via `shouldFailHandshake`),
        // so `consecutiveFailures` climbs 1 -> 2 -> 3 -> 4 -> 5 and the delay before each attempt
        // follows `backoffDuration(forAttempt:)` evaluated at the *current* failure count —
        // 2s, 4s, 8s, 16s — matching `swissarmyhammer-lsp`'s `restart_with_backoff`.
        let expectedDelays: [Duration] = [.seconds(2), .seconds(4), .seconds(8), .seconds(16)]
        for expectedDelay in expectedDelays {
            let restartTask = Task { try? await daemon.restartWithBackoff() }
            await clock.waitForWaiter()
            clock.advance(by: expectedDelay)
            await restartTask.value
        }

        state = await daemon.state()
        guard case let .failed(_, finalAttempts) = state else {
            Issue.record("expected .failed, got \(state)")
            return
        }
        #expect(finalAttempts == 5)

        // The failure budget is now exhausted: a further restart must be refused immediately,
        // without sleeping against the clock at all.
        await #expect(throws: CodeContextError.self) {
            try await daemon.restartWithBackoff()
        }
        state = await daemon.state()
        guard case let .failed(_, attemptsAfterGiveUp) = state else {
            Issue.record("expected .failed, got \(state)")
            return
        }
        #expect(attemptsAfterGiveUp == 5, "giving up must not itself record another failure")

        // Recovery: once the connection factory stops failing the handshake, `forceRestart()`
        // resets the counter and starts fresh.
        await shouldFailHandshake.set(false)
        await processState.setAlive(true)
        try await daemon.forceRestart()
        state = await daemon.state()
        #expect(state == .running(pid: 1))
    }

    // MARK: - forceRestart()

    @Test
    func forceRestartResetsConsecutiveFailureCount() async throws {
        let processState = ProcessState()
        let daemon = LSPDaemon<FakeLanguageServerConnection>(
            spec: Self.serverSpec(),
            workspaceRoot: Self.workspaceRoot,
            clock: ManualClock(),
            connectionFactory: fakeConnectionFactory(pid: 7, processState: processState)
        )
        try await daemon.start()
        await processState.setAlive(false)
        _ = await daemon.healthCheck()
        var state = await daemon.state()
        guard case .failed = state else {
            Issue.record("expected .failed after the crash, got \(state)")
            return
        }

        await processState.setAlive(true)
        try await daemon.forceRestart()

        state = await daemon.state()
        #expect(state == .running(pid: 7))

        // The counter was reset, so a fresh crash is recorded as attempt 1 again, not 2.
        await processState.setAlive(false)
        _ = await daemon.healthCheck()
        state = await daemon.state()
        guard case let .failed(_, attempts) = state else {
            Issue.record("expected .failed, got \(state)")
            return
        }
        #expect(attempts == 1)
    }

    // MARK: - shutdown()

    @Test
    func shutdownSendsShutdownAndExitAndReachesNotStarted() async throws {
        let processState = ProcessState()
        let capturedConnection = Box<FakeLanguageServerConnection?>(nil)
        let daemon = LSPDaemon<FakeLanguageServerConnection>(
            spec: Self.serverSpec(),
            workspaceRoot: Self.workspaceRoot,
            clock: ManualClock(),
            connectionFactory: fakeConnectionFactory(pid: 1, processState: processState) { connection in
                await capturedConnection.set(connection)
            }
        )
        try await daemon.start()

        await daemon.shutdown()

        let state = await daemon.state()
        #expect(state == .notStarted)
        let session = await daemon.session()
        #expect(session == nil)

        let connection = try #require(await capturedConnection.value)
        let calls = await connection.calls
        #expect(calls.contains(.shutdown))
        #expect(calls.contains(.exit))
        let shutdownIndex = try #require(calls.firstIndex(of: .shutdown))
        let exitIndex = try #require(calls.firstIndex(of: .exit))
        #expect(shutdownIndex < exitIndex, "shutdown must be sent before exit")

        let terminateCount = await processState.terminateCount
        #expect(terminateCount == 0, "a process that exits on its own must not be force-killed")
    }

    @Test
    func shutdownForceKillsAfterGraceTimeoutElapses() async throws {
        let clock = ManualClock()
        let processState = ProcessState()
        await processState.setHangsOnWaitForExit(true)

        let daemon = LSPDaemon<FakeLanguageServerConnection>(
            spec: Self.serverSpec(),
            workspaceRoot: Self.workspaceRoot,
            clock: clock,
            connectionFactory: fakeConnectionFactory(pid: 1, processState: processState)
        )
        try await daemon.start()
        let grace = Duration.seconds(5)
        await daemon.setShutdownGrace(grace)

        let shutdownTask = Task { await daemon.shutdown() }
        await clock.waitForWaiter()
        clock.advance(by: grace)
        await shutdownTask.value

        let state = await daemon.state()
        #expect(state == .notStarted)
        let terminateCount = await processState.terminateCount
        #expect(terminateCount == 1, "an unresponsive process must be force-killed once the grace period elapses")
    }

    @Test
    func shutdownWhenNotStartedIsANoOp() async {
        let processState = ProcessState()
        let daemon = LSPDaemon<FakeLanguageServerConnection>(
            spec: Self.serverSpec(),
            workspaceRoot: Self.workspaceRoot,
            clock: ManualClock(),
            connectionFactory: fakeConnectionFactory(pid: 1, processState: processState)
        )
        await daemon.shutdown()
        let state = await daemon.state()
        #expect(state == .notStarted)
    }
}

/// A `LanguageServerConnection` whose `initialize(rootURI:)` never returns, for exercising
/// `LSPDaemon`'s handshake-timeout path deterministically. Every other requirement forwards to an
/// internal `FakeLanguageServerConnection`, which this test never exercises but must still
/// implement to satisfy the protocol.
private actor HangingInitializeConnection: LanguageServerConnection {
    private let inner = FakeLanguageServerConnection()

    nonisolated var serverNotifications: AsyncStream<ServerNotification> { inner.serverNotifications }

    func initialize(rootURI: DocumentURI?) async throws {
        try await Task.sleep(for: .seconds(3600))
    }

    func initialized() async throws { try await inner.initialized() }
    func shutdown() async throws { try await inner.shutdown() }
    func exit() async throws { try await inner.exit() }

    func didOpen(uri: DocumentURI, languageID: String, version: Int, text: String) async throws {
        try await inner.didOpen(uri: uri, languageID: languageID, version: version, text: text)
    }
    func didChange(uri: DocumentURI, version: Int, text: String) async throws {
        try await inner.didChange(uri: uri, version: version, text: text)
    }
    func didSave(uri: DocumentURI) async throws { try await inner.didSave(uri: uri) }
    func didClose(uri: DocumentURI) async throws { try await inner.didClose(uri: uri) }

    func documentSymbols(in uri: DocumentURI) async throws -> [DocumentSymbol] {
        try await inner.documentSymbols(in: uri)
    }
    func definition(in uri: DocumentURI, at position: Position) async throws -> [Location] {
        try await inner.definition(in: uri, at: position)
    }
    func typeDefinition(in uri: DocumentURI, at position: Position) async throws -> [Location] {
        try await inner.typeDefinition(in: uri, at: position)
    }
    func hover(in uri: DocumentURI, at position: Position) async throws -> Hover? {
        try await inner.hover(in: uri, at: position)
    }
    func references(in uri: DocumentURI, at position: Position, includeDeclaration: Bool) async throws -> [Location] {
        try await inner.references(in: uri, at: position, includeDeclaration: includeDeclaration)
    }
    func implementations(in uri: DocumentURI, at position: Position) async throws -> [Location] {
        try await inner.implementations(in: uri, at: position)
    }

    func prepareCallHierarchy(in uri: DocumentURI, at position: Position) async throws -> [CallHierarchyItem] {
        try await inner.prepareCallHierarchy(in: uri, at: position)
    }
    func outgoingCalls(of item: CallHierarchyItem) async throws -> [CallHierarchyOutgoingCall] {
        try await inner.outgoingCalls(of: item)
    }
    func incomingCalls(of item: CallHierarchyItem) async throws -> [CallHierarchyIncomingCall] {
        try await inner.incomingCalls(of: item)
    }

    func prepareRename(in uri: DocumentURI, at position: Position) async throws -> PrepareRenameResult {
        try await inner.prepareRename(in: uri, at: position)
    }
    func rename(in uri: DocumentURI, at position: Position, newName: String) async throws -> WorkspaceEdit {
        try await inner.rename(in: uri, at: position, newName: newName)
    }

    func codeActions(in uri: DocumentURI, range: LSPRange, diagnostics: [Diagnostic], only: [String]?) async throws -> [CodeActionItem] {
        try await inner.codeActions(in: uri, range: range, diagnostics: diagnostics, only: only)
    }
    func resolveCodeAction(item: CodeActionItem) async throws -> CodeActionItem {
        try await inner.resolveCodeAction(item: item)
    }

    func workspaceSymbols(query: String) async throws -> [SymbolInformation] {
        try await inner.workspaceSymbols(query: query)
    }

    func pullDiagnostics(for uri: DocumentURI) async throws -> [Diagnostic] {
        try await inner.pullDiagnostics(for: uri)
    }
}
