import Foundation

/// One managed daemon's command name paired with its current lifecycle state, as reported by
/// `LspSupervisor.status()`.
///
/// Ports `swissarmyhammer-lsp`'s `DaemonStatus`. `state` already carries the daemon's pid
/// (`.running(pid:)`) and consecutive-failure count (`.failed(reason:attempts:)`), so this type
/// adds no further fields beyond the command identifying which managed daemon the state belongs to.
struct ServerStatus: Sendable, Equatable {
    /// The server executable this status describes, matching the owning daemon's `ServerSpec.command`.
    let command: String

    /// The daemon's lifecycle state at the moment `status()` was called.
    let state: LspDaemonState

    /// Creates a server status snapshot.
    /// - Parameters:
    ///   - command: The server executable this status describes.
    ///   - state: The daemon's lifecycle state at the moment of the snapshot.
    init(command: String, state: LspDaemonState) {
        self.command = command
        self.state = state
    }
}

/// Manages the fleet of `LspDaemon`s for one workspace: project detection, one daemon per unique
/// server command, a periodic per-daemon health loop, and coordinated shutdown.
///
/// Ports `swissarmyhammer-lsp`'s `LspSupervisorManager`, minus leader election — out of scope for
/// this Swift port (see plan.md's LSP subsystem). `start()` runs
/// `ProjectDetection.detectProjects(rootDirectory:)` against the workspace root, collects
/// `ServerSpec`s deduped by command via `ProjectDetection.serverSpecs(for:)`, and spawns one
/// `LspDaemon<Connection>` per spec not already managed, all sharing this supervisor's
/// `connectionFactory` and `clock` and all bound to the same workspace root as `rootUri`. Every
/// newly started daemon also gets its own repeating health-check task, paced by that daemon's own
/// `ServerSpec.healthCheckInterval`, that calls `healthCheck()` and — mirroring
/// `swissarmyhammer-lsp`'s `should_attempt_restart` — attempts `restartWithBackoff()` only when the
/// daemon lands in `.failed` afterward (never `.notFound`, `.notStarted`, or `.shuttingDown`).
actor LspSupervisor<Connection: LanguageServerConnection> {
    /// One daemon this supervisor owns, alongside the spec it was built from and its running
    /// health-check task.
    private struct ManagedDaemon {
        /// The daemon this entry manages.
        let daemon: LspDaemon<Connection>

        /// The spec this daemon was built from, supplying the health loop's pacing interval.
        let spec: ServerSpec

        /// The daemon's repeating health-check task, cancelled by `shutdown()`.
        var healthLoopTask: Task<Void, Never>?
    }

    /// The workspace root passed to project detection and every daemon's `rootUri`.
    private let workspaceRoot: URL

    /// The clock every managed daemon and this supervisor's health loops sleep against.
    private let clock: any Clock<Duration>

    /// Spawns a fresh connection for every daemon this supervisor creates.
    private let connectionFactory: ConnectionFactory<Connection>

    /// Every daemon this supervisor manages, keyed by `ServerSpec.command`.
    private var managedDaemons: [String: ManagedDaemon] = [:]

    /// Test-only hook invoked once per `LspDaemon` this supervisor constructs in
    /// `spawnDaemons(for:)`, right after construction and before that daemon's own `start()` is
    /// attempted — regardless of whether the `$PATH` lookup inside `start()` ultimately succeeds.
    ///
    /// Test-only seam, mirroring `LspDaemon`'s `setShutdownGrace`: lets a test count or otherwise
    /// observe daemon-construction attempts (e.g. to verify `start()`'s coalescing under genuinely
    /// concurrent callers) without depending on a real, installed language-server binary — unlike
    /// `connectionFactory`, which `LspDaemon.start()` only calls once its `$PATH` lookup succeeds.
    private var daemonConstructedHookForTesting: (@Sendable (ServerSpec) -> Void)?

    /// The in-flight `start()` spawn round, if one is running.
    ///
    /// `start()`'s body reads `managedDaemons` to compute which specs are new, then suspends for
    /// the whole concurrent spawn (`await spawnDaemons(for:)`) before writing the results back.
    /// Without coalescing, two overlapping `start()` calls would both read the same
    /// not-yet-updated `managedDaemons`, both decide the same command is "new", and both spawn a
    /// daemon for it — the second write would silently orphan the first daemon (and its
    /// never-cancelled health-loop task). Routing every call through this single in-flight task
    /// makes concurrent `start()` calls await the same spawn round instead of racing.
    private var inFlightStart: Task<Void, Error>?

    /// Creates a supervisor for `workspaceRoot`. No daemons are spawned until `start()` is called.
    /// - Parameters:
    ///   - workspaceRoot: The workspace root passed to project detection and every daemon's `rootUri`.
    ///   - clock: The clock every managed daemon and this supervisor's health loops sleep against.
    ///     Defaults to `ContinuousClock()`; tests inject a `ManualClock`.
    ///   - connectionFactory: Spawns a fresh connection for every daemon this supervisor creates.
    init(
        workspaceRoot: URL,
        clock: any Clock<Duration> = ContinuousClock(),
        connectionFactory: @escaping ConnectionFactory<Connection>
    ) {
        self.workspaceRoot = workspaceRoot
        self.clock = clock
        self.connectionFactory = connectionFactory
    }

    // MARK: - Lifecycle

    /// Detects projects under the workspace root and starts one daemon per unique server command
    /// not already managed.
    ///
    /// Ports `swissarmyhammer-lsp`'s `start`: runs `ProjectDetection.detectProjects`, collects
    /// `ServerSpec`s deduped by command via `ProjectDetection.serverSpecs(for:)`, skips any command
    /// already managed (so a repeated `start()` call is additive, never duplicating a daemon), then
    /// builds and starts every new daemon concurrently. Each daemon's own `start()` failure (a
    /// missing binary, a failed handshake) is logged and left visible via that daemon's state
    /// (`.notFound`/`.failed`) rather than aborting the other daemons or this method. Every newly
    /// started daemon also gets a repeating health-check task, paced by its own
    /// `ServerSpec.healthCheckInterval`.
    ///
    /// Concurrent callers coalesce onto the same spawn round via `inFlightStart` rather than each
    /// independently detecting the same "new" command and racing to insert a daemon for it — see
    /// `inFlightStart`'s documentation.
    /// - Throws: Rethrows `ProjectDetection.detectProjects(rootDirectory:)`'s errors.
    func start() async throws {
        if let inFlightStart {
            try await inFlightStart.value
            return
        }
        let spawnRound = Task { try await self.performStart() }
        inFlightStart = spawnRound
        defer { inFlightStart = nil }
        try await spawnRound.value
    }

    /// Does the actual work of one `start()` spawn round; see `start()` for the coalescing wrapper
    /// around this.
    /// - Throws: Rethrows `ProjectDetection.detectProjects(rootDirectory:)`'s errors.
    private func performStart() async throws {
        let detectedProjects = try ProjectDetection.detectProjects(rootDirectory: workspaceRoot)
        let specs = ProjectDetection.serverSpecs(for: detectedProjects)
        let newSpecs = specs.filter { managedDaemons[$0.command] == nil }
        guard !newSpecs.isEmpty else { return }

        for (spec, daemon) in await spawnDaemons(for: newSpecs) {
            managedDaemons[spec.command] = ManagedDaemon(
                daemon: daemon,
                spec: spec,
                healthLoopTask: startHealthLoop(command: spec.command, spec: spec, daemon: daemon)
            )
        }
    }

    /// Builds one `LspDaemon` per spec and starts every one of them concurrently.
    ///
    /// Each daemon's `start()` failure is logged but never rethrown: a missing binary or a failed
    /// handshake for one server must not prevent the other servers in `specs` from starting, and
    /// the failure remains visible via that daemon's own state.
    /// - Parameter specs: The specs to build and start daemons for.
    /// - Returns: One `(ServerSpec, LspDaemon<Connection>)` pair per spec, in no particular order.
    private func spawnDaemons(for specs: [ServerSpec]) async -> [(ServerSpec, LspDaemon<Connection>)] {
        let root = workspaceRoot
        let daemonClock = clock
        let factory = connectionFactory
        let constructedHook = daemonConstructedHookForTesting

        return await withTaskGroup(of: (ServerSpec, LspDaemon<Connection>).self) { group in
            for spec in specs {
                group.addTask {
                    let daemon = LspDaemon<Connection>(
                        spec: spec,
                        workspaceRoot: root,
                        clock: daemonClock,
                        connectionFactory: factory
                    )
                    constructedHook?(spec)
                    do {
                        try await daemon.start()
                    } catch {
                        Log.lsp.warning(
                            "LSP daemon failed to start (\(spec.command, privacy: .public)): \(error.localizedDescription, privacy: .public)"
                        )
                    }
                    return (spec, daemon)
                }
            }
            var results: [(ServerSpec, LspDaemon<Connection>)] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }

    /// Starts one daemon's repeating health-check task, paced by `spec.healthCheckInterval`.
    ///
    /// Each iteration sleeps for the interval against the injected clock, calls `healthCheck()`,
    /// and — mirroring `swissarmyhammer-lsp`'s `should_attempt_restart` — attempts
    /// `restartWithBackoff()` only when the daemon is unhealthy *and* landed in `.failed`
    /// afterward, leaving `.notFound`, `.notStarted`, and `.shuttingDown` daemons untouched.
    /// - Parameters:
    ///   - command: The daemon's server command, used only for log messages.
    ///   - spec: The spec supplying the health-check pacing interval.
    ///   - daemon: The daemon this task health-checks and restarts.
    /// - Returns: The repeating task, cancelled by `shutdown()`.
    private func startHealthLoop(
        command: String,
        spec: ServerSpec,
        daemon: LspDaemon<Connection>
    ) -> Task<Void, Never> {
        let daemonClock = clock
        return Task {
            while !Task.isCancelled {
                do {
                    try await daemonClock.sleep(for: spec.healthCheckInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }

                let isHealthy = await daemon.healthCheck()
                guard !isHealthy else { continue }
                guard case .failed = await daemon.state() else { continue }
                // Re-checked immediately before the restart call: `shutdown()` cancels this task
                // and then awaits its completion before tearing the daemon down, so bailing out
                // here (rather than starting a restart that `shutdown()` would otherwise have to
                // race) guarantees a shutdown that lands between the state check above and this
                // point can never be undone by a subsequent restart.
                guard !Task.isCancelled else { return }

                do {
                    try await daemon.restartWithBackoff()
                } catch {
                    Log.lsp.warning(
                        "LSP daemon restart attempt failed (\(command, privacy: .public)): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
    }

    /// Gracefully shuts down every managed daemon concurrently.
    ///
    /// Cancels every daemon's health-check task, then *awaits* each one's actual completion before
    /// calling any daemon's own `shutdown()`. Cancelling alone isn't enough: a health-loop task
    /// already past its pre-restart cancellation check (see `startHealthLoop`) is mid-flight inside
    /// `daemon.restartWithBackoff()`, an actor call that doesn't itself observe cancellation, so it
    /// could otherwise still be running — and could still resurrect the daemon to `.running` —
    /// concurrently with, or even after, this method calls `daemon.shutdown()`. Waiting for every
    /// health-loop task to finish first guarantees no in-flight restart is still racing
    /// `daemon.shutdown()` by the time it's called, so shutdown is always the last word. Managed
    /// daemon entries are preserved — `status()` still reports them, now `.notStarted` — matching
    /// `swissarmyhammer-lsp`'s `shutdown` (a fleet shutdown never removes daemon entries).
    func shutdown() async {
        let healthLoopTasks = managedDaemons.values.compactMap(\.healthLoopTask)
        for command in managedDaemons.keys {
            managedDaemons[command]?.healthLoopTask?.cancel()
            managedDaemons[command]?.healthLoopTask = nil
        }
        for healthLoopTask in healthLoopTasks {
            await healthLoopTask.value
        }

        let daemons = managedDaemons.values.map(\.daemon)
        await withTaskGroup(of: Void.self) { group in
            for daemon in daemons {
                group.addTask { await daemon.shutdown() }
            }
        }
    }

    // MARK: - Status and control

    /// A snapshot of every managed daemon's current state, sorted by command for deterministic
    /// output.
    /// - Returns: One `ServerStatus` per managed daemon.
    func status() async -> [ServerStatus] {
        var statuses: [ServerStatus] = []
        for (command, managed) in managedDaemons {
            let state = await managed.daemon.state()
            statuses.append(ServerStatus(command: command, state: state))
        }
        return statuses.sorted { $0.command < $1.command }
    }

    /// Force-restarts the managed daemon for `command`, bypassing backoff.
    /// - Parameter command: The server command identifying which managed daemon to restart.
    /// - Throws: `CodeContextError.notFound` if no daemon is managed for `command`; otherwise
    ///   whatever the daemon's `forceRestart()` throws.
    func forceRestart(command: String) async throws {
        guard let managed = managedDaemons[command] else {
            throw CodeContextError.notFound("no LSP daemon managing command: \(command)")
        }
        try await managed.daemon.forceRestart()
    }

    // MARK: - Session routing

    /// The current session for the daemon serving `fileExtension`, if that language has a
    /// registered server and its daemon is running.
    ///
    /// Routes through `Languages.module(forFileExtension:)` to find the owning module, then that
    /// module's `languageServer.command` to find the managed daemon — so extensions sharing one
    /// server (e.g. `"ts"` and `"tsx"` both routing to `typescript-language-server`) return the
    /// same session.
    /// - Parameter fileExtension: The extension to route, without a leading dot, matched
    ///   case-insensitively (see `Languages.module(forFileExtension:)`).
    /// - Returns: The routed daemon's current session, or `nil` if the extension is unregistered,
    ///   its module has no language server, or that server's daemon isn't currently running.
    func session(forFileExtension fileExtension: String) async -> LspSession<Connection>? {
        guard let module = Languages.module(forFileExtension: fileExtension),
              let spec = module.languageServer,
              let managed = managedDaemons[spec.command]
        else {
            return nil
        }
        return await managed.daemon.session()
    }

    /// The first running session among every managed daemon, in command-sorted order.
    ///
    /// Useful for a caller that needs *some* live LSP session regardless of language, e.g. a health
    /// probe.
    /// - Returns: The first non-`nil` session found, or `nil` if no managed daemon is running.
    func anySession() async -> LspSession<Connection>? {
        for command in managedDaemons.keys.sorted() {
            guard let managed = managedDaemons[command] else { continue }
            if let session = await managed.daemon.session() {
                return session
            }
        }
        return nil
    }

    // MARK: - Test support

    /// Installs (or clears) `daemonConstructedHookForTesting`.
    ///
    /// Test-only seam; see `daemonConstructedHookForTesting`'s documentation.
    /// - Parameter hook: Called once per `LspDaemon` this supervisor constructs, with the spec it
    ///   was built from. Pass `nil` to remove a previously installed hook.
    func setDaemonConstructedHookForTesting(_ hook: (@Sendable (ServerSpec) -> Void)?) {
        daemonConstructedHookForTesting = hook
    }

    /// Directly inserts an already-configured daemon into this supervisor's managed fleet and
    /// starts its health-check loop, bypassing `start()`'s project-detection step.
    ///
    /// Test-only seam: mirrors `swissarmyhammer-lsp`'s test-only `insert_daemon` helper. Lets
    /// supervisor tests drive a daemon that was built and started independently (e.g. under a
    /// `ServerSpec` whose `command` is a real, PATH-resolvable executable so its handshake can
    /// actually complete against a scripted connection) without depending on real project detection
    /// or an installed language-server binary. `spec` need not be the same spec the daemon was
    /// constructed with — only `spec.command` (the routing/dedupe key) and
    /// `spec.healthCheckInterval` (the health loop's pacing) matter here.
    /// - Parameters:
    ///   - spec: The spec identifying the daemon by `spec.command` and supplying its health-check
    ///     interval.
    ///   - daemon: The daemon to manage.
    func insertDaemonForTesting(spec: ServerSpec, daemon: LspDaemon<Connection>) {
        // Cancel any prior entry's health-loop task under this command first, mirroring `start()`'s
        // own dedupe-by-command guard: overwriting a managed entry must never leak the health-loop
        // task it displaces.
        managedDaemons[spec.command]?.healthLoopTask?.cancel()
        managedDaemons[spec.command] = ManagedDaemon(
            daemon: daemon,
            spec: spec,
            healthLoopTask: startHealthLoop(command: spec.command, spec: spec, daemon: daemon)
        )
    }
}

extension LspSupervisor where Connection == ProcessLanguageServerConnection {
    /// Creates a supervisor wired to spawn real subprocess-backed daemons for `workspaceRoot`.
    /// - Parameters:
    ///   - workspaceRoot: The workspace root passed to project detection and every daemon's `rootUri`.
    ///   - clock: The clock every managed daemon and this supervisor's health loops sleep against.
    ///     Defaults to `ContinuousClock()`.
    /// - Returns: A supervisor whose `connectionFactory` spawns real child processes via
    ///   `LspDaemon.processConnectionFactory(clock:)`.
    static func production(
        workspaceRoot: URL,
        clock: any Clock<Duration> = ContinuousClock()
    ) -> LspSupervisor {
        LspSupervisor(
            workspaceRoot: workspaceRoot,
            clock: clock,
            connectionFactory: LspDaemon<ProcessLanguageServerConnection>.processConnectionFactory(clock: clock)
        )
    }
}
