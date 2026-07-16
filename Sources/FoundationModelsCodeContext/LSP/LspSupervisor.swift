import Foundation

/// One managed daemon's command name paired with its current lifecycle state, as reported by
/// `LspSupervisor.status()`.
///
/// Ports `swissarmyhammer-lsp`'s `DaemonStatus`. `state` already carries the daemon's pid
/// (`.running(pid:)`) and consecutive-failure count (`.failed(reason:attempts:)`), so this type
/// adds no further fields beyond the command identifying which managed daemon the state belongs to.
public struct ServerStatus: Sendable, Equatable, Codable, Identifiable {
    /// The server executable this status describes, matching the owning daemon's `ServerSpec.command`.
    public let command: String

    /// The daemon's lifecycle state at the moment `status()` was called.
    public let state: LSPDaemonState

    /// Conforms `ServerStatus` to `Identifiable` for direct use in SwiftUI's `ForEach(state.servers) { ... }`
    /// (see plan.md's "Goal" example) — `command` is already the supervisor's own uniqueness key (one
    /// daemon per unique server command), so it needs no separate synthesized identifier.
    public var id: String { command }

    /// Creates a server status snapshot.
    /// - Parameters:
    ///   - command: The server executable this status describes.
    ///   - state: The daemon's lifecycle state at the moment of the snapshot.
    public init(command: String, state: LSPDaemonState) {
        self.command = command
        self.state = state
    }
}

/// Manages the fleet of `LSPDaemon`s for one workspace: project detection, one daemon per unique
/// server command, a periodic per-daemon health loop, and coordinated shutdown.
///
/// Ports `swissarmyhammer-lsp`'s `LspSupervisorManager`, minus leader election — out of scope for
/// this Swift port (see plan.md's LSP subsystem). `start()` runs
/// `ProjectDetection.detectProjects(rootDirectory:)` against the workspace root, collects
/// `ServerSpec`s deduped by command via `ProjectDetection.serverSpecs(for:)`, and spawns one
/// `LSPDaemon<Connection>` per spec not already managed, all sharing this supervisor's
/// `connectionFactory` and `clock` and all bound to the same workspace root as `rootUri`. Every
/// newly started daemon also gets its own repeating health-check task, paced by that daemon's own
/// `ServerSpec.healthCheckInterval`, that calls `healthCheck()` and — mirroring
/// `swissarmyhammer-lsp`'s `should_attempt_restart` — attempts `restartWithBackoff()` only when the
/// daemon lands in `.failed` afterward (never `.notFound`, `.notStarted`, or `.shuttingDown`).
actor LspSupervisor<Connection: LanguageServerConnection> {
    /// One daemon this supervisor owns, alongside the spec it was built from, its running
    /// health-check task, and its in-flight auto-install task (if any).
    private struct ManagedDaemon {
        /// The daemon this entry manages.
        let daemon: LSPDaemon<Connection>

        /// The spec this daemon was built from, supplying the health loop's pacing interval.
        let spec: ServerSpec

        /// The daemon's repeating health-check task, cancelled by `shutdown()`.
        var healthLoopTask: Task<Void, Never>?

        /// The one-shot auto-install task started by `triggerAutoInstallIfNeeded(spec:daemon:)`
        /// for a daemon that landed in `.notFound` on its initial spawn, if any. Cancelled and
        /// awaited by `shutdown()`, mirroring `healthLoopTask`.
        var installTask: Task<Void, Never>?
    }

    /// The workspace root passed to project detection and every daemon's `rootUri`.
    private let workspaceRoot: URL

    /// The clock every managed daemon and this supervisor's health loops sleep against.
    private let clock: any Clock<Duration>

    /// Spawns a fresh connection for every daemon this supervisor creates.
    private let connectionFactory: ConnectionFactory<Connection>

    /// The opt-out policy gating whether a `.notFound` daemon's binary is ever auto-installed —
    /// see `triggerAutoInstallIfNeeded(spec:daemon:)`.
    private let autoInstall: LspAutoInstall

    /// Runs a spec's machine-actionable installer on this supervisor's behalf, subject to
    /// `autoInstall`. Owned (not injected as a whole object) so every managed daemon's install
    /// attempts share one instance's at-most-once-per-command dedupe.
    private let installer: ServerInstaller

    /// Every daemon this supervisor manages, keyed by `ServerSpec.command`.
    private var managedDaemons: [String: ManagedDaemon] = [:]

    /// Test-only hook invoked once per `LSPDaemon` this supervisor constructs in
    /// `spawnDaemons(for:)`, right after construction and before that daemon's own `start()` is
    /// attempted — regardless of whether the `$PATH` lookup inside `start()` ultimately succeeds.
    ///
    /// Test-only seam, mirroring `LSPDaemon`'s `setShutdownGrace`: lets a test count or otherwise
    /// observe daemon-construction attempts (e.g. to verify `start()`'s coalescing under genuinely
    /// concurrent callers) without depending on a real, installed language-server binary — unlike
    /// `connectionFactory`, which `LSPDaemon.start()` only calls once its `$PATH` lookup succeeds.
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
    ///   - autoInstall: The opt-out policy gating whether a `.notFound` daemon's binary is ever
    ///     auto-installed. Defaults to `LspAutoInstall()` (enabled, 300-second timeout).
    ///   - installRunner: The process-running seam `installer` drives. Defaults to
    ///     `ProcessInstallRunner()`; tests inject a scripted `FakeInstallRunner`.
    ///   - connectionFactory: Spawns a fresh connection for every daemon this supervisor creates.
    init(
        workspaceRoot: URL,
        clock: any Clock<Duration> = ContinuousClock(),
        autoInstall: LspAutoInstall = LspAutoInstall(),
        installRunner: any InstallRunner = ProcessInstallRunner(),
        connectionFactory: @escaping ConnectionFactory<Connection>
    ) {
        self.workspaceRoot = workspaceRoot
        self.clock = clock
        self.autoInstall = autoInstall
        self.installer = ServerInstaller(policy: autoInstall, runner: installRunner)
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

    /// Builds a `ManagedDaemon` for `spec`/`daemon`, starts its health-check loop, and stores it
    /// under `spec.command`.
    ///
    /// Shared by `performStart` (registering freshly spawned daemons) and
    /// `insertDaemonForTesting` (registering a daemon built and started independently), so the
    /// construction/assignment logic exists in exactly one place. Callers that are replacing an
    /// existing entry are responsible for cancelling its prior `healthLoopTask` first — this
    /// method only ever adds a fresh one.
    /// - Parameters:
    ///   - spec: The spec identifying the daemon by `spec.command` and supplying its health-check
    ///     interval.
    ///   - daemon: The daemon to manage.
    private func registerManagedDaemon(spec: ServerSpec, daemon: LSPDaemon<Connection>) {
        managedDaemons[spec.command] = ManagedDaemon(
            daemon: daemon,
            spec: spec,
            healthLoopTask: startHealthLoop(command: spec.command, spec: spec, daemon: daemon)
        )
    }

    /// Does the actual work of one `start()` spawn round; see `start()` for the coalescing wrapper
    /// around this.
    /// - Throws: Rethrows `ProjectDetection.detectProjects(rootDirectory:)`'s errors.
    private func performStart() async throws {
        let detectedProjects = try ProjectDetection.detectProjects(rootDirectory: workspaceRoot)
        let specs = ProjectDetection.serverSpecs(for: detectedProjects)
        await spawnAndRegister(specs: specs)
    }

    /// Spawns and registers a daemon for every spec in `specs` not already managed, triggering an
    /// auto-install attempt for any that land in `.notFound`. Shared by `performStart` (specs from
    /// real project detection) and `startForTesting(specs:)` (specs supplied directly by a test).
    /// - Parameter specs: The candidate specs; any already managed by `spec.command` are skipped.
    private func spawnAndRegister(specs: [ServerSpec]) async {
        let newSpecs = specs.filter { managedDaemons[$0.command] == nil }
        guard !newSpecs.isEmpty else { return }

        for (spec, daemon) in await spawnDaemons(for: newSpecs) {
            registerManagedDaemon(spec: spec, daemon: daemon)
            await triggerAutoInstallIfNeeded(spec: spec, daemon: daemon)
        }
    }

    /// Starts an auto-install attempt for `daemon` if its initial spawn attempt landed it in
    /// `.notFound`, `spec` carries a machine-actionable installer, and `autoInstall` is enabled —
    /// a no-op otherwise (including today's behavior for a disabled policy or a `nil` installer:
    /// the daemon is simply left `.notFound`, and no install task is ever created).
    ///
    /// Calls `daemon.noteInstalling()` synchronously — before this method (and therefore
    /// `performStart()`/`start()`) returns — so a caller reading `supervisor.status()` right after
    /// `start()` returns can never observe a still-settled `.notFound` daemon that is actually
    /// about to start installing (see `LSPDaemon.noteInstalling()`'s documentation). The install
    /// attempt itself then runs on an owned, unstructured background task — installs can take
    /// minutes, so this must not block `start()` — tracked as `installTask` on that daemon's
    /// managed entry and cancelled+awaited by `shutdown()`, mirroring the per-daemon health-check
    /// tasks.
    /// - Parameters:
    ///   - spec: The spec the daemon was spawned from.
    ///   - daemon: The freshly spawned (and already-registered) daemon to check.
    private func triggerAutoInstallIfNeeded(spec: ServerSpec, daemon: LSPDaemon<Connection>) async {
        guard autoInstall.isEnabled, spec.installer != nil else { return }
        guard await daemon.state() == .notFound else { return }

        await daemon.noteInstalling()
        managedDaemons[spec.command]?.installTask = startInstallTask(spec: spec, daemon: daemon)
    }

    /// Spawns the background task that runs one auto-install attempt for `spec` and then, on
    /// *both* success and failure, force-restarts `daemon` — the single mechanism that exits
    /// `.installing`: the restarted lookup (which also covers `spec.installer?.extraSearchDirectories`)
    /// lands `.running` if the install delivered the binary, or re-lands `.notFound` if it didn't.
    /// `ServerInstaller`'s own at-most-once-per-command guard is what prevents a re-`.notFound`
    /// daemon from ever triggering a second install for the same command.
    ///
    /// Guards `!Task.isCancelled` before calling `forceRestart()`, mirroring `startHealthLoop`'s
    /// own pre-restart cancellation check: a `shutdown()` that cancels and awaits this task before
    /// it reaches that point can never be undone by a subsequent restart.
    /// - Parameters:
    ///   - spec: The spec identifying the command to install and, on completion, to restart.
    ///   - daemon: The `.installing` daemon to restart once the install attempt completes.
    /// - Returns: The spawned task, cancelled and awaited by `shutdown()`.
    private func startInstallTask(spec: ServerSpec, daemon: LSPDaemon<Connection>) -> Task<Void, Never> {
        let installer = self.installer
        return Task {
            _ = await installer.install(spec: spec)
            guard !Task.isCancelled else { return }
            try? await daemon.forceRestart()
        }
    }

    /// Builds one `LSPDaemon` per spec and starts every one of them concurrently.
    ///
    /// Each daemon's `start()` failure is logged but never rethrown: a missing binary or a failed
    /// handshake for one server must not prevent the other servers in `specs` from starting, and
    /// the failure remains visible via that daemon's own state.
    /// - Parameter specs: The specs to build and start daemons for.
    /// - Returns: One `(ServerSpec, LSPDaemon<Connection>)` pair per spec, in no particular order.
    private func spawnDaemons(for specs: [ServerSpec]) async -> [(ServerSpec, LSPDaemon<Connection>)] {
        let root = workspaceRoot
        let daemonClock = clock
        let factory = connectionFactory
        let constructedHook = daemonConstructedHookForTesting

        return await withTaskGroup(of: (ServerSpec, LSPDaemon<Connection>).self) { group in
            for spec in specs {
                group.addTask {
                    let daemon = LSPDaemon<Connection>(
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
            var results: [(ServerSpec, LSPDaemon<Connection>)] = []
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
        daemon: LSPDaemon<Connection>
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
    /// Cancels every daemon's health-check *and* install task, then *awaits* each one's actual
    /// completion before calling any daemon's own `shutdown()`. Cancelling alone isn't enough: a
    /// health-loop task already past its pre-restart cancellation check (see `startHealthLoop`),
    /// or an install task already past its own pre-restart cancellation check (see
    /// `startInstallTask`), is mid-flight inside `daemon.restartWithBackoff()`/`forceRestart()` —
    /// an actor call that doesn't itself observe cancellation — so it could otherwise still be
    /// running — and could still resurrect the daemon to `.running` — concurrently with, or even
    /// after, this method calls `daemon.shutdown()`. Waiting for every health-loop and install
    /// task to finish first guarantees no in-flight restart is still racing `daemon.shutdown()` by
    /// the time it's called, so shutdown is always the last word, and it stays prompt: an
    /// in-flight install itself is cancelled and (per `ProcessInstallRunner`'s own cancellation
    /// handling) torn down quickly rather than run to completion. Managed daemon entries are
    /// preserved — `status()` still reports them, now `.notStarted` — matching
    /// `swissarmyhammer-lsp`'s `shutdown` (a fleet shutdown never removes daemon entries).
    func shutdown() async {
        let healthLoopTasks = managedDaemons.values.compactMap(\.healthLoopTask)
        let installTasks = managedDaemons.values.compactMap(\.installTask)
        for command in managedDaemons.keys {
            managedDaemons[command]?.healthLoopTask?.cancel()
            managedDaemons[command]?.healthLoopTask = nil
            managedDaemons[command]?.installTask?.cancel()
            managedDaemons[command]?.installTask = nil
        }
        for healthLoopTask in healthLoopTasks {
            await healthLoopTask.value
        }
        for installTask in installTasks {
            await installTask.value
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
    /// - Parameter hook: Called once per `LSPDaemon` this supervisor constructs, with the spec it
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
    func insertDaemonForTesting(spec: ServerSpec, daemon: LSPDaemon<Connection>) {
        // Cancel any prior entry's health-loop and install tasks under this command first,
        // mirroring `start()`'s own dedupe-by-command guard: overwriting a managed entry must
        // never leak either task it displaces.
        managedDaemons[spec.command]?.healthLoopTask?.cancel()
        managedDaemons[spec.command]?.installTask?.cancel()
        registerManagedDaemon(spec: spec, daemon: daemon)
    }

    /// Runs `performStart()`'s real spawn-then-register-then-maybe-auto-install pipeline against
    /// `specs` supplied directly by a test, bypassing real project detection entirely.
    ///
    /// Test-only seam: `insertDaemonForTesting(spec:daemon:)` registers an already-built,
    /// already-started daemon and therefore never exercises `triggerAutoInstallIfNeeded(spec:daemon:)`
    /// — the auto-install tests need a spec's `LSPDaemon` to be freshly constructed and started by
    /// this supervisor itself (so its `.notFound` transition and the ensuing auto-install trigger
    /// happen for real), without depending on `ProjectDetection` finding a real project marker or a
    /// real language-server binary.
    /// - Parameter specs: The specs to spawn and register, exactly as `performStart()` would with
    ///   specs from real project detection.
    func startForTesting(specs: [ServerSpec]) async {
        await spawnAndRegister(specs: specs)
    }
}

extension LspSupervisor where Connection == ProcessLanguageServerConnection {
    /// Creates a supervisor wired to spawn real subprocess-backed daemons for `workspaceRoot`.
    /// - Parameters:
    ///   - workspaceRoot: The workspace root passed to project detection and every daemon's `rootUri`.
    ///   - clock: The clock every managed daemon and this supervisor's health loops sleep against.
    ///     Defaults to `ContinuousClock()`.
    ///   - autoInstall: The opt-out policy gating whether a `.notFound` daemon's binary is ever
    ///     auto-installed. Defaults to `LspAutoInstall()` (enabled, 300-second timeout).
    /// - Returns: A supervisor whose `connectionFactory` spawns real child processes via
    ///   `LSPDaemon.processConnectionFactory(clock:)`.
    static func production(
        workspaceRoot: URL,
        clock: any Clock<Duration> = ContinuousClock(),
        autoInstall: LspAutoInstall = LspAutoInstall()
    ) -> LspSupervisor {
        LspSupervisor(
            workspaceRoot: workspaceRoot,
            clock: clock,
            autoInstall: autoInstall,
            connectionFactory: LSPDaemon<ProcessLanguageServerConnection>.processConnectionFactory(clock: clock)
        )
    }
}
