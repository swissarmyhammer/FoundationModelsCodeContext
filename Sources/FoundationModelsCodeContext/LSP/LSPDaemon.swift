import Foundation

/// The lifecycle state of one `LSPDaemon`-managed language-server process.
///
/// Ports `swissarmyhammer-lsp`'s `types::LSPDaemonState` as a Swift enum observed via
/// `LSPDaemon.stateUpdates`. Every state below can transition into `.failed` (an unexpected
/// exit, a spawn failure, or a handshake failure/timeout), and every state but `.notStarted`
/// can be reached again via a restart.
///
/// `LSPDaemonState` (and `ServerStatus`, which embeds it) is `public Codable`. Adding, removing,
/// or renaming a case changes the type's encoded schema — Swift's synthesized enum-with-payload
/// `Codable` conformance encodes the case name itself as a keyed-container key. No decode site
/// for either type exists inside this repo (both are only ever encoded, for `ServerStatus`'s
/// SwiftUI/CLI consumers), but any external consumer that decodes a persisted `ServerStatus`
/// value must be rebuilt against the version of this package that produced it.
public enum LSPDaemonState: Sendable, Equatable, Codable {
    /// The daemon has never been started, or has completed a graceful `shutdown()`.
    case notStarted

    /// `spec.command` was not found on `$PATH` (or, once resolved, `spec.installer`'s
    /// `extraSearchDirectories`); the daemon will not spawn until `forceRestart()`.
    case notFound

    /// The server binary is missing and an auto-install attempt is in flight, entered via
    /// `noteInstalling()`. Not settled — see `CodeContextState.isSettled` — a workspace mid-install
    /// is not ready, matching how `.starting` is treated. There is no dedicated "install failed"
    /// case: the daemon leaves `.installing` on both outcomes via `forceRestart()`, whose re-run of
    /// `start()`'s binary lookup naturally lands `.running` (the binary is now present) or
    /// `.notFound` (still missing) — see `noteInstalling()`'s documentation.
    case installing

    /// The child process has been spawned and the `initialize`/`initialized` handshake is in flight.
    case starting

    /// The server is running and passed its handshake. `pid` is the child process id.
    case running(pid: Int32)

    /// The server exited unexpectedly, failed to spawn, or failed its handshake. `attempts` is
    /// the number of consecutive failures recorded since the last successful start.
    case failed(reason: String, attempts: Int)

    /// A graceful shutdown (`shutdown` request + `exit` notification) is in progress.
    case shuttingDown
}

/// The process-level hooks `LSPDaemon` needs for one spawned connection, beyond what
/// `LanguageServerConnection` exposes.
///
/// `LanguageServerConnection` is scoped to LSP-capability requests only (per plan.md's LSP
/// subsystem design), so every concrete connection — including the in-memory
/// `FakeLanguageServerConnection` tests program against — stays free of process-management
/// concerns. `LSPDaemon` needs those concerns anyway: a pid to report in `.running(pid:)`, a way
/// to detect an unexpected exit, a way to wait for a graceful exit, and a way to force-terminate
/// a hung handshake or an unresponsive shutdown. A `ConnectionFactory` bundles them into this
/// handle alongside the connection itself, so tests can control each hook independently of the
/// connection's own scripted LSP responses.
struct ConnectionHandle<Connection: LanguageServerConnection>: Sendable {
    /// The live connection, handed to the daemon's `LspSession`.
    let connection: Connection

    /// The child process id, reported in `LSPDaemonState.running(pid:)`.
    let pid: Int32

    /// Reports whether the underlying process is still alive.
    let isAlive: @Sendable () async -> Bool

    /// Suspends until the underlying process exits, returning immediately if it already has.
    let waitForExit: @Sendable () async -> Void

    /// Forcibly terminates the underlying process.
    let terminate: @Sendable () async -> Void

    /// Returns a best-effort tail of the underlying process's recent stderr output.
    let stderrTail: @Sendable () async -> String

    /// Creates a connection handle bundling a live connection with the process-level hooks
    /// `LSPDaemon` needs beyond the `LanguageServerConnection` protocol.
    /// - Parameters:
    ///   - connection: The live connection, handed to the daemon's `LspSession`.
    ///   - pid: The child process id, reported in `LSPDaemonState.running(pid:)`.
    ///   - isAlive: Reports whether the underlying process is still alive.
    ///   - waitForExit: Suspends until the underlying process exits, returning immediately if it
    ///     already has.
    ///   - terminate: Forcibly terminates the underlying process.
    ///   - stderrTail: Returns a best-effort tail of the underlying process's recent stderr
    ///     output. Defaults to always returning an empty string.
    init(
        connection: Connection,
        pid: Int32,
        isAlive: @escaping @Sendable () async -> Bool,
        waitForExit: @escaping @Sendable () async -> Void,
        terminate: @escaping @Sendable () async -> Void,
        stderrTail: @escaping @Sendable () async -> String = { "" }
    ) {
        self.connection = connection
        self.pid = pid
        self.isAlive = isAlive
        self.waitForExit = waitForExit
        self.terminate = terminate
        self.stderrTail = stderrTail
    }
}

/// Spawns one language-server connection for a `ServerSpec`, bound to a workspace root.
///
/// Injected into `LSPDaemon` so it never spawns a real process under test: production code
/// supplies `LSPDaemon.processConnectionFactory()`; tests supply a factory that wraps
/// `FakeLanguageServerConnection` with test-controlled `isAlive`/`waitForExit`/`terminate` hooks.
typealias ConnectionFactory<Connection: LanguageServerConnection> = @Sendable (
    ServerSpec, URL
) async throws -> ConnectionHandle<Connection>

/// Owns the lifecycle of one LSP server child process: spawning, the `initialize`/`initialized`
/// handshake, health-check-driven auto-restart with exponential backoff, and graceful shutdown.
///
/// Ports `swissarmyhammer-lsp`'s `daemon::LSPDaemon` as a Swift actor generic over the
/// `LanguageServerConnection` it drives — production code instantiates
/// `LSPDaemon<ProcessLanguageServerConnection>` via `processConnectionFactory()`; tests
/// instantiate `LSPDaemon<FakeLanguageServerConnection>` with a connection factory under full
/// control, per plan.md's LSP subsystem design. State transitions
/// (`notStarted → starting → running(pid) → failed(reason, attempts) → shuttingDown`, plus
/// `notFound`) are observable via `stateUpdates`. This actor does not run its own timers: health
/// checks and the restart cadence are driven by an external caller (the forthcoming
/// `LspSupervisor`) calling `healthCheck()` and `restartWithBackoff()`.
actor LSPDaemon<Connection: LanguageServerConnection> {
    /// Consecutive failures allowed before `restartWithBackoff()` refuses to retry further.
    private static var maxConsecutiveFailures: Int { 5 }

    /// The default grace period `shutdown()` waits for the server to exit on its own before
    /// force-terminating it.
    private static var defaultShutdownGrace: Duration { .seconds(5) }

    /// The server specification this daemon spawns and monitors.
    private let spec: ServerSpec

    /// The workspace root advertised to the server as its `rootUri`.
    private let workspaceRoot: URL

    /// Spawns a fresh connection on every `start()` call.
    private let connectionFactory: ConnectionFactory<Connection>

    /// The clock `restartWithBackoff()` and the handshake/shutdown timeouts sleep against.
    private let clock: any Clock<Duration>

    /// The currently running connection's process-level hooks, or `nil` when not running.
    private var handle: ConnectionHandle<Connection>?

    /// The session over the current connection, or `nil` when not running.
    private var currentSession: LspSession<Connection>?

    /// The number of consecutive failures recorded since the last successful `start()`.
    private var consecutiveFailures = 0

    /// Whether the "binary not found" warning has already been logged, so repeated failed
    /// restarts against a missing binary don't spam the log.
    private var hasWarnedNotFound = false

    /// The grace period `shutdown()` waits for the server to exit on its own before
    /// force-terminating it. Overridable so tests can probe the timeout-then-kill path without
    /// waiting out the production default.
    private var shutdownGrace: Duration

    /// The daemon's current lifecycle state.
    private var currentState: LSPDaemonState = .notStarted {
        didSet { stateContinuation.yield(currentState) }
    }

    /// The write side of `stateUpdates`.
    private let stateContinuation: AsyncStream<LSPDaemonState>.Continuation

    /// A single-consumer stream of every state transition this daemon makes from the moment of
    /// construction onward, mirroring `ProcessLanguageServerConnection`'s `serverNotifications`.
    nonisolated let stateUpdates: AsyncStream<LSPDaemonState>

    /// Creates a daemon for `spec`, bound to `workspaceRoot`, that spawns connections via
    /// `connectionFactory`.
    /// - Parameters:
    ///   - spec: The server specification to spawn and monitor.
    ///   - workspaceRoot: The workspace root advertised to the server as its `rootUri`.
    ///   - clock: The clock backoff sleeps, handshake timeouts, and the shutdown grace period
    ///     wait against. Defaults to `ContinuousClock()`; tests inject a `ManualClock`.
    ///   - connectionFactory: Spawns a fresh connection on every `start()` call. Production code
    ///     passes `processConnectionFactory()`; tests pass one backed by a fake connection.
    init(
        spec: ServerSpec,
        workspaceRoot: URL,
        clock: any Clock<Duration> = ContinuousClock(),
        connectionFactory: @escaping ConnectionFactory<Connection>
    ) {
        self.spec = spec
        self.workspaceRoot = workspaceRoot
        self.clock = clock
        self.connectionFactory = connectionFactory
        self.shutdownGrace = Self.defaultShutdownGrace
        let (stream, continuation) = AsyncStream.makeStream(of: LSPDaemonState.self)
        self.stateUpdates = stream
        self.stateContinuation = continuation
    }

    /// Overrides the graceful-shutdown grace period.
    ///
    /// Test-only seam: production code relies on the default `defaultShutdownGrace`; tests that
    /// deliberately drive the timeout branch set a short period so they assert the
    /// timeout-then-kill behavior in milliseconds instead of seconds.
    /// - Parameter grace: The new grace period `shutdown()` waits before force-terminating.
    func setShutdownGrace(_ grace: Duration) {
        shutdownGrace = grace
    }

    /// A snapshot of the daemon's current lifecycle state.
    /// - Returns: The current `LSPDaemonState`.
    func state() -> LSPDaemonState {
        currentState
    }

    /// The command name of the server this daemon manages.
    /// - Returns: `spec.command`, unchanged from the spec this daemon was created with.
    func command() -> String {
        spec.command
    }

    /// The session driving the current connection, if the server is running.
    ///
    /// Unlike `swissarmyhammer-lsp`'s `LSPDaemon::session`, which keeps one `LspSession` alive
    /// for the daemon's whole lifetime over a swappable client handle, this port builds a fresh
    /// `LspSession` on every successful `start()` (one per `Connection` instance, since
    /// `LspSession`'s connection is an immutable `let`). Callers must therefore call `session()`
    /// again after any restart rather than caching the result across one: a cached reference
    /// keeps pointing at the connection from the start it was fetched after, which a later
    /// restart replaces without that reference's knowledge.
    /// - Returns: The current `LspSession`, or `nil` if the daemon isn't running.
    func session() -> LspSession<Connection>? {
        currentSession
    }

    // MARK: - Lifecycle

    /// Transitions the daemon into `.installing`: "the server binary is missing and an
    /// auto-install attempt is in flight." The supervisor calls this right before invoking
    /// `ServerInstaller`, so the state is observable via `stateUpdates`/`ServerStatus` for the
    /// whole duration of the install — and, per `CodeContextState.isSettled`, `.installing` is not
    /// settled, so a workspace mid-install correctly reports `isReady == false`.
    ///
    /// Valid only from `.notFound` or `.notStarted` — the two states in which the binary is known
    /// (or presumed) not yet spawnable. Any other current state is a programmer error (e.g. the
    /// supervisor racing an install trigger against a daemon that has already started, or against
    /// one mid-shutdown) and this call is a no-op, logged via `Log.lsp.fault` rather than silently
    /// swallowed.
    ///
    /// No `noteInstallFailed()` counterpart exists: the daemon leaves `.installing` on *both*
    /// outcomes the same way, via `forceRestart()` — whose re-run of `start()`'s binary lookup
    /// naturally lands `.running` (the binary is now present) or `.notFound` (still missing).
    func noteInstalling() {
        guard currentState == .notFound || currentState == .notStarted else {
            Log.lsp.fault(
                "noteInstalling() called from unexpected state for \(self.spec.command, privacy: .public); expected .notFound or .notStarted, ignoring"
            )
            return
        }
        currentState = .installing
    }

    /// Starts the LSP server: locates the binary on `$PATH` (falling back to
    /// `spec.installer?.extraSearchDirectories` for a native-installer binary that landed
    /// somewhere not on `$PATH`), spawns a connection via the injected factory, and completes the
    /// `initialize`/`initialized` handshake bounded by `spec.startupTimeout`.
    ///
    /// On success the state becomes `.running(pid:)` and `consecutiveFailures` resets to zero. On
    /// failure the state becomes `.notFound` (binary missing everywhere — `consecutiveFailures` is
    /// left untouched, matching `swissarmyhammer-lsp`'s `start`) or `.failed(reason:attempts:)`
    /// (spawn failure, handshake failure, or handshake timeout — each increments
    /// `consecutiveFailures`).
    /// - Throws: `CodeContextError.binaryNotFound` if `spec.command` isn't found on `$PATH` or in
    ///   any of `spec.installer?.extraSearchDirectories`; `CodeContextError.handshakeFailed` if the
    ///   handshake fails or times out; whatever the connection factory throws if spawning the
    ///   connection fails.
    func start() async throws {
        guard let location = BinaryLookup.resolve(
            command: spec.command,
            extraSearchDirectories: spec.installer?.extraSearchDirectories ?? []
        ) else {
            if !hasWarnedNotFound {
                Log.lsp.warning(
                    "LSP binary not found on PATH: \(self.spec.command, privacy: .public) (\(self.spec.installHint, privacy: .public))"
                )
                hasWarnedNotFound = true
            }
            currentState = .notFound
            throw CodeContextError.binaryNotFound(command: spec.command, installHint: spec.installHint)
        }

        currentState = .starting

        let spawnedHandle: ConnectionHandle<Connection>
        do {
            spawnedHandle = try await connectionFactory(Self.spawnSpec(for: spec, location: location), workspaceRoot)
        } catch {
            recordFailure(reason: "spawn failed: \(error.localizedDescription)")
            throw error
        }

        do {
            try await performHandshake(handle: spawnedHandle)
        } catch {
            await spawnedHandle.terminate()
            let reason = await Self.handshakeFailureReason(error: error, handle: spawnedHandle)
            recordFailure(reason: reason)
            throw CodeContextError.handshakeFailed(reason)
        }

        handle = spawnedHandle
        currentSession = LspSession(connection: spawnedHandle.connection, languageID: spec.languageIDs.first ?? "plaintext")
        consecutiveFailures = 0
        currentState = .running(pid: spawnedHandle.pid)
    }

    /// Checks whether the currently running connection's process is still alive.
    ///
    /// On an unexpected exit, tears down the connection, clears the current session's
    /// open-document set (a fresh process on the next `start()` knows nothing about what the dead
    /// one had open), and records a failure — mirroring `swissarmyhammer-lsp`'s `health_check`.
    /// - Returns: `true` if the process is still alive; `false` if it has exited (or the daemon
    ///   isn't running), in which case the state is now `.failed(reason:attempts:)`.
    @discardableResult
    func healthCheck() async -> Bool {
        guard let handle else { return false }
        if await handle.isAlive() {
            return true
        }
        Log.lsp.error("LSP server exited unexpectedly: \(self.spec.command, privacy: .public)")
        await currentSession?.resetDocuments()
        self.handle = nil
        currentSession = nil
        recordFailure(reason: "process exited unexpectedly")
        return false
    }

    /// Attempts to restart the server after a failure, respecting the exponential-backoff policy.
    ///
    /// Ports `swissarmyhammer-lsp`'s `restart_with_backoff`: the delay before the restart attempt
    /// is `backoffDuration(forAttempt:)` evaluated at the current `consecutiveFailures` count (1s,
    /// 2s, 4s, 8s, 16s, 32s, capped at 60s), and the daemon gives up once `consecutiveFailures` has
    /// reached `maxConsecutiveFailures` (5) — the state stays `.failed` until `forceRestart()`.
    /// - Throws: `CodeContextError.handshakeFailed` if the failure budget is already exhausted;
    ///   otherwise whatever `start()` throws.
    func restartWithBackoff() async throws {
        guard consecutiveFailures < Self.maxConsecutiveFailures else {
            throw CodeContextError.handshakeFailed(
                "too many consecutive failures (\(consecutiveFailures)), giving up"
            )
        }
        let delay = Self.backoffDuration(forAttempt: consecutiveFailures)
        try await clock.sleep(for: delay)
        try await start()
    }

    /// Force-restarts the server, resetting the consecutive-failure counter and the
    /// "binary not found" warning so a rediscovered binary is reported again if it's still
    /// missing.
    ///
    /// Shuts down the current process (if any), then starts fresh — bypassing the backoff delay
    /// entirely, per `swissarmyhammer-lsp`'s `force_restart`.
    /// - Throws: Whatever `start()` throws.
    func forceRestart() async throws {
        await shutdown()
        consecutiveFailures = 0
        hasWarnedNotFound = false
        try await start()
    }

    /// Gracefully shuts down the running server: sends `shutdown` then `exit`, waits for the
    /// process to exit on its own bounded by `shutdownGrace`, and force-terminates it if that
    /// grace period elapses. A no-op that transitions straight to `.notStarted` if the daemon
    /// isn't running. Resets `consecutiveFailures` to zero: a deliberate shutdown is a clean
    /// slate, not a failure, so a later `start()` should not inherit backoff state from before
    /// this call.
    func shutdown() async {
        consecutiveFailures = 0
        guard let handle else {
            currentState = .notStarted
            return
        }

        await currentSession?.resetDocuments()
        currentState = .shuttingDown

        // Best-effort: the server may already be gone, in which case these just fail silently —
        // the grace-bounded wait below is what actually determines when we give up and kill it.
        try? await handle.connection.shutdown()
        try? await handle.connection.exit()

        let daemonClock = clock
        let grace = shutdownGrace
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await handle.waitForExit() }
            group.addTask { try? await daemonClock.sleep(for: grace) }
            await group.next()
            group.cancelAll()
        }

        if await handle.isAlive() {
            Log.lsp.warning(
                "LSP server did not exit within the shutdown grace period, killing: \(self.spec.command, privacy: .public)"
            )
            await handle.terminate()
        } else {
            Log.lsp.info("LSP server shut down gracefully: \(self.spec.command, privacy: .public)")
        }

        self.handle = nil
        self.currentSession = nil
        currentState = .notStarted
    }

    // MARK: - Internal helpers

    /// Builds the `ServerSpec` to hand the connection factory for a binary resolved at `location`.
    ///
    /// `ConnectionFactory` is `(ServerSpec, URL) -> ConnectionHandle` — there is no separate
    /// "resolved command path" parameter, and the production factory
    /// (`processConnectionFactory()`) always spawns `spec.command` directly. So when
    /// `BinaryLookup.resolve` found the binary only via one of
    /// `spec.installer?.extraSearchDirectories` rather than on `$PATH`, the factory needs a
    /// *different* `command` value than this daemon's own `spec.command` in order to spawn the
    /// right binary. `location == .onPath` returns `spec` unchanged — the common case, and the
    /// only case for a `spec` without an `installer`.
    ///
    /// This daemon's own stored `spec` (and therefore `command()`/`ServerStatus.command`) is never
    /// touched by this: it stays the bare name, which is the supervisor's dedupe and
    /// session-routing key.
    /// - Parameters:
    ///   - spec: The daemon's own spec, used as the base for the returned copy.
    ///   - location: Where `BinaryLookup.resolve` found `spec.command`.
    /// - Returns: `spec` unchanged for `.onPath`; otherwise a full-memberwise-init copy with
    ///   `command` replaced by the resolved absolute path.
    private static func spawnSpec(for spec: ServerSpec, location: BinaryLookup.Location) -> ServerSpec {
        guard case .extraSearchDirectory(let absolutePath) = location else { return spec }
        return ServerSpec(
            command: absolutePath,
            arguments: spec.arguments,
            languageIDs: spec.languageIDs,
            startupTimeout: spec.startupTimeout,
            healthCheckInterval: spec.healthCheckInterval,
            installHint: spec.installHint,
            installer: spec.installer
        )
    }

    /// Runs the `initialize`/`initialized` handshake over `handle.connection`, bounded by
    /// `spec.startupTimeout` via the injected clock.
    /// - Parameter handle: The freshly spawned connection to complete the handshake over.
    /// - Throws: Whatever `connection.initialize`/`connection.initialized` throw, or
    ///   `CodeContextError.timeout` if `spec.startupTimeout` elapses first.
    private func performHandshake(handle: ConnectionHandle<Connection>) async throws {
        let timeout = spec.startupTimeout
        let daemonClock = clock
        let connection = handle.connection
        let rootURI = DocumentURI(workspaceRoot.absoluteString)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await connection.initialize(rootURI: rootURI)
                try await connection.initialized()
            }
            group.addTask {
                try await daemonClock.sleep(for: timeout)
                throw CodeContextError.timeout(timeout)
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    /// Builds a handshake-failure reason string, appending a best-effort stderr tail when one is
    /// available.
    /// - Parameters:
    ///   - error: The error the handshake failed or timed out with.
    ///   - handle: The connection handle to capture a stderr tail from.
    /// - Returns: `error`'s localized description, with `"; stderr: <tail>"` appended if `handle`
    ///   captured any stderr output.
    private static func handshakeFailureReason(error: Error, handle: ConnectionHandle<Connection>) async -> String {
        let description = error.localizedDescription
        let stderrTail = await handle.stderrTail()
        guard !stderrTail.isEmpty else { return description }
        return "\(description); stderr: \(stderrTail)"
    }

    /// Increments the consecutive-failure counter and transitions to `.failed`.
    /// - Parameter reason: A human-readable description of what failed.
    private func recordFailure(reason: String) {
        consecutiveFailures += 1
        Log.lsp.error(
            "LSP daemon failure (\(self.spec.command, privacy: .public), attempt \(self.consecutiveFailures)): \(reason, privacy: .public)"
        )
        currentState = .failed(reason: reason, attempts: consecutiveFailures)
    }

    /// Computes the exponential-backoff delay for the given zero-indexed consecutive-failure
    /// count.
    ///
    /// Ports `swissarmyhammer-lsp`'s `backoff_duration`: doubles from 1 second per attempt,
    /// capped at 60 seconds (1, 2, 4, 8, 16, 32, 60, 60, ...).
    /// - Parameter attempt: The number of consecutive failures already recorded (0-indexed).
    /// - Returns: The delay to wait before the next restart attempt.
    static func backoffDuration(forAttempt attempt: Int) -> Duration {
        let capSeconds: Int64 = 60
        guard attempt >= 0, attempt < 62 else {
            return .seconds(capSeconds)
        }
        let doubledSeconds = Int64(1) << attempt
        return .seconds(min(doubledSeconds, capSeconds))
    }
}

extension LSPDaemon where Connection == ProcessLanguageServerConnection {
    /// The production connection factory: spawns a real `ProcessLanguageServerConnection` child
    /// process for the given spec.
    ///
    /// Wires `ProcessLanguageServerConnection`'s pid, liveness, exit-wait, and stderr-tail hooks
    /// into a `ConnectionHandle` so `LSPDaemon` can drive it without knowing about `Process`
    /// directly. `close()` doubles as the "terminate" hook: it already tears down the process and
    /// every pipe.
    /// - Parameter clock: The clock the spawned connection's own per-request timeout sleeps
    ///   against. Defaults to `ContinuousClock()`.
    /// - Returns: A factory that spawns `spec.command` with `spec.arguments` as a real child process,
    ///   ignoring the workspace root (the connection itself is workspace-agnostic; the daemon
    ///   passes the root separately to the `initialize` handshake).
    static func processConnectionFactory(
        clock: any Clock<Duration> = ContinuousClock()
    ) -> ConnectionFactory<ProcessLanguageServerConnection> {
        { spec, _ in
            let connection = try ProcessLanguageServerConnection(
                command: spec.command,
                arguments: spec.arguments,
                clock: clock
            )
            return ConnectionHandle(
                connection: connection,
                pid: connection.pid,
                isAlive: { await connection.isRunning() },
                waitForExit: { await connection.waitUntilExit() },
                terminate: { await connection.close() },
                stderrTail: { connection.recentStderrTail() }
            )
        }
    }
}
