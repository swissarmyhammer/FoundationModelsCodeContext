import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// Tests for `LspSupervisor`, driven entirely against `FakeLanguageServerConnection` and a
/// `ManualClock` so no real subprocess is ever spawned and no real wall-clock time is ever waited.
///
/// Covers `start()`'s project detection → dedupe-by-command daemon fleet (including that repeated
/// `start()` calls are additive, never duplicating an already-managed daemon), the per-daemon
/// health loop's restart dispatch (only a daemon that lands in `.failed` after a health check is
/// restarted), `session(forFileExtension:)`/`anySession()` routing, `forceRestart(command:)`, and
/// concurrent `shutdown()`.
struct LspSupervisorTests {
    // MARK: - Fixtures

    /// Builds a `ServerSpec` for tests. `command` defaults to `"true"` — a real, near-instant Unix
    /// utility — so `LSPDaemon`'s `$PATH` lookup (not mockable; a genuine filesystem check)
    /// succeeds on every test runner without actually being spawned: the connection factory always
    /// substitutes a `FakeLanguageServerConnection` before any real process would be launched.
    private static func serverSpec(
        command: String = "true",
        healthCheckInterval: Duration = .seconds(60)
    ) -> ServerSpec {
        ServerSpec(
            command: command,
            languageIDs: ["fake"],
            healthCheckInterval: healthCheckInterval,
            installHint: "install the fake LSP server"
        )
    }

    /// A workspace root fixture for tests that never touch the filesystem-based project detection
    /// path (routing, health-loop, shutdown, force-restart tests all insert daemons directly).
    private static let workspaceRoot = URL(fileURLWithPath: "/tmp/lsp-supervisor-tests")

    // `ProcessState` and `fakeConnectionFactory` live in `Support/FakeDaemonProcess.swift`, shared
    // with `LSPDaemonTests`.

    /// Polls `predicate` at 1ms real-time intervals until it returns `true` or `timeout` elapses.
    ///
    /// Bridges a `ManualClock`-driven async chain (e.g. a health loop's restart, running on its own
    /// unstructured `Task`) with the cooperative thread pool's actual scheduling: releasing a
    /// `ManualClock` waiter via `advance(by:)` resumes the suspended task, but doesn't itself
    /// guarantee that task has finished running by the time the caller's next line executes. Mirrors
    /// `ManualClock.waitForWaiter()`'s own real-time polling loop.
    /// - Parameters:
    ///   - timeout: How long to keep polling before giving up. Defaults to 5 seconds.
    ///   - predicate: The condition to poll for.
    private static func waitUntil(
        timeout: Duration = .seconds(5),
        _ predicate: @Sendable () async -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    // MARK: - start() / dedupe

    @Test
    func startWithNoDetectedProjectsManagesNoDaemons() async throws {
        try await withTemporaryWorkspace { root in
            let supervisor = LspSupervisor<FakeLanguageServerConnection>(
                workspaceRoot: root,
                clock: ManualClock(),
                connectionFactory: fakeConnectionFactory(pid: 1, processState: ProcessState())
            )

            try await supervisor.start()

            let statuses = await supervisor.status()
            #expect(statuses.isEmpty)
        }
    }

    @Test
    func startDedupesPolyglotFixtureToExactlyTwoDaemons() async throws {
        try await withTemporaryWorkspace { root in
            try write("[package]\nname = \"backend\"", to: "backend/Cargo.toml", in: root)
            try write("{\"name\": \"web\"}", to: "frontend/package.json", in: root)
            try write("{\"name\": \"admin\"}", to: "admin/package.json", in: root)

            let supervisor = LspSupervisor<FakeLanguageServerConnection>(
                workspaceRoot: root,
                clock: ManualClock(),
                connectionFactory: fakeConnectionFactory(pid: 1, processState: ProcessState())
            )

            try await supervisor.start()

            let statuses = await supervisor.status()
            let commands = Set(statuses.map(\.command))
            #expect(commands == ["rust-analyzer", "typescript-language-server"])
            #expect(statuses.count == 2, "two js dirs sharing typescript-language-server must dedupe to one daemon")
        }
    }

    @Test
    func startIsAdditiveAcrossRepeatedCallsWithoutDuplicatingManagedDaemons() async throws {
        try await withTemporaryWorkspace { root in
            try write("[package]\nname = \"a\"", to: "Cargo.toml", in: root)

            let supervisor = LspSupervisor<FakeLanguageServerConnection>(
                workspaceRoot: root,
                clock: ManualClock(),
                connectionFactory: fakeConnectionFactory(pid: 1, processState: ProcessState())
            )

            try await supervisor.start()
            try await supervisor.start()

            let statuses = await supervisor.status()
            #expect(statuses.count == 1)
            #expect(statuses[0].command == "rust-analyzer")
        }
    }

    @Test
    func trulyConcurrentStartCallsCoalesceWithoutDuplicatingOrOrphaningADaemon() async throws {
        try await withTemporaryWorkspace { root in
            try write("[package]\nname = \"backend\"", to: "backend/Cargo.toml", in: root)
            try write("{\"name\": \"web\"}", to: "frontend/package.json", in: root)
            try write("{\"name\": \"admin\"}", to: "admin/package.json", in: root)

            let supervisor = LspSupervisor<FakeLanguageServerConnection>(
                workspaceRoot: root,
                clock: ManualClock(),
                connectionFactory: fakeConnectionFactory(pid: 1, processState: ProcessState())
            )

            // `connectionFactory` only runs once a daemon's `$PATH` lookup succeeds, which real
            // registry commands like "rust-analyzer" can't be relied on to do on an arbitrary test
            // machine — so orphaned/duplicate daemon *constructions* are counted directly via this
            // test-only hook instead, which fires regardless of PATH outcome.
            let constructionCount = Counter()
            await supervisor.setDaemonConstructedHookForTesting { _ in
                Task { await constructionCount.increment() }
            }

            // Ten genuinely concurrent (not sequentially awaited) callers racing the same spawn
            // round, exercising `inFlightStart`'s coalescing rather than serialized calls. Without
            // coalescing, each of the ten could independently observe an empty `managedDaemons`
            // and spawn its own pair of daemons, so `constructionCount` would climb well past 2.
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<10 {
                    group.addTask { try await supervisor.start() }
                }
                for try await _ in group {}
            }

            let statuses = await supervisor.status()
            let commands = statuses.map(\.command)
            #expect(Set(commands) == ["rust-analyzer", "typescript-language-server"])
            #expect(commands.count == Set(commands).count, "concurrent start() calls must never duplicate a managed daemon")

            await Self.waitUntil { await constructionCount.value == 2 }
            let finalConstructionCount = await constructionCount.value
            #expect(
                finalConstructionCount == 2,
                "coalescing must construct exactly one daemon per unique command, got \(finalConstructionCount)"
            )
        }
    }

    // MARK: - session(forFileExtension:) / anySession()

    @Test
    func sessionRoutesTypeScriptAndTSXExtensionsToTheSameSession() async throws {
        let clock = ManualClock()
        let processState = ProcessState()
        let daemon = LSPDaemon<FakeLanguageServerConnection>(
            spec: Self.serverSpec(command: "true"),
            workspaceRoot: Self.workspaceRoot,
            clock: clock,
            connectionFactory: fakeConnectionFactory(pid: 1, processState: processState)
        )
        try await daemon.start()

        let supervisor = LspSupervisor<FakeLanguageServerConnection>(
            workspaceRoot: Self.workspaceRoot,
            clock: clock,
            connectionFactory: fakeConnectionFactory(pid: 1, processState: processState)
        )
        // Keyed under the real registry command so `Languages.module(forFileExtension:)`'s routing
        // chain finds it; the daemon itself was started under a PATH-friendly spec above.
        await supervisor.insertDaemonForTesting(
            spec: Self.serverSpec(command: "typescript-language-server"),
            daemon: daemon
        )

        let expectedSession = try #require(await daemon.session())
        let tsSession = await supervisor.session(forFileExtension: "ts")
        let tsxSession = await supervisor.session(forFileExtension: "tsx")
        #expect(tsSession === expectedSession)
        #expect(tsxSession === expectedSession)
    }

    @Test
    func sessionReturnsNilForUnknownExtension() async {
        let supervisor = LspSupervisor<FakeLanguageServerConnection>(
            workspaceRoot: Self.workspaceRoot,
            clock: ManualClock(),
            connectionFactory: fakeConnectionFactory(pid: 1, processState: ProcessState())
        )

        let session = await supervisor.session(forFileExtension: "not-a-real-extension")
        #expect(session == nil)
    }

    @Test
    func anySessionReturnsNilWhenNoDaemonIsManaged() async {
        let supervisor = LspSupervisor<FakeLanguageServerConnection>(
            workspaceRoot: Self.workspaceRoot,
            clock: ManualClock(),
            connectionFactory: fakeConnectionFactory(pid: 1, processState: ProcessState())
        )

        let session = await supervisor.anySession()
        #expect(session == nil)
    }

    @Test
    func anySessionReturnsARunningDaemonsSession() async throws {
        let clock = ManualClock()
        let processState = ProcessState()
        let daemon = LSPDaemon<FakeLanguageServerConnection>(
            spec: Self.serverSpec(command: "true"),
            workspaceRoot: Self.workspaceRoot,
            clock: clock,
            connectionFactory: fakeConnectionFactory(pid: 1, processState: processState)
        )
        try await daemon.start()

        let supervisor = LspSupervisor<FakeLanguageServerConnection>(
            workspaceRoot: Self.workspaceRoot,
            clock: clock,
            connectionFactory: fakeConnectionFactory(pid: 1, processState: processState)
        )
        await supervisor.insertDaemonForTesting(spec: Self.serverSpec(command: "true"), daemon: daemon)

        let expectedSession = try #require(await daemon.session())
        let session = await supervisor.anySession()
        #expect(session === expectedSession)
    }

    // MARK: - health loop restart dispatch

    @Test
    func healthLoopRestartsADeadDaemonAndLeavesHealthyDaemonsUntouched() async throws {
        let clock = ManualClock()
        let healthyProcess = ProcessState()
        let deadProcess = ProcessState()
        let healthySpec = Self.serverSpec(command: "true", healthCheckInterval: .seconds(30))
        let deadSpec = Self.serverSpec(command: "false", healthCheckInterval: .seconds(30))

        let healthyDaemon = LSPDaemon<FakeLanguageServerConnection>(
            spec: healthySpec,
            workspaceRoot: Self.workspaceRoot,
            clock: clock,
            connectionFactory: fakeConnectionFactory(pid: 1, processState: healthyProcess)
        )
        let deadDaemon = LSPDaemon<FakeLanguageServerConnection>(
            spec: deadSpec,
            workspaceRoot: Self.workspaceRoot,
            clock: clock,
            connectionFactory: fakeConnectionFactory(pid: 2, processState: deadProcess)
        )
        try await healthyDaemon.start()
        try await deadDaemon.start()

        let supervisor = LspSupervisor<FakeLanguageServerConnection>(
            workspaceRoot: Self.workspaceRoot,
            clock: clock,
            connectionFactory: fakeConnectionFactory(pid: 0, processState: ProcessState())
        )
        await supervisor.insertDaemonForTesting(spec: healthySpec, daemon: healthyDaemon)
        await supervisor.insertDaemonForTesting(spec: deadSpec, daemon: deadDaemon)

        // Simulate the dead daemon's process exiting before the health-check tick fires.
        await deadProcess.setAlive(false)

        // Release both daemons' first health-check tick. Both health loops are independent tasks
        // racing to register their initial 30s sleep, so waiting for only one waiter here (rather
        // than both) could let `advance(by:)` run before the second one has registered — that
        // straggler's `sleep(for:)` would then compute its deadline from the already-advanced
        // clock, pushing its own first check a full interval late.
        await clock.waitForWaiter(count: 2)
        clock.advance(by: .seconds(30))

        // After that tick, the healthy daemon's loop immediately re-registers its next 30s sleep
        // while the dead daemon's loop runs its health check and then registers the backoff sleep
        // below — again two independent, racing registrations, so wait for both before advancing.
        //
        // The dead daemon's restart attempt sleeps for the first backoff step, evaluated at
        // consecutiveFailures == 1 (already incremented by the health check that just failed):
        // backoffDuration(forAttempt: 1) == 2 seconds.
        await clock.waitForWaiter(count: 2)
        clock.advance(by: .seconds(2))

        await Self.waitUntil { await deadDaemon.state() == .running(pid: 2) }

        let healthyState = await healthyDaemon.state()
        #expect(healthyState == .running(pid: 1), "a healthy daemon must not be restarted")

        let deadState = await deadDaemon.state()
        #expect(deadState == .running(pid: 2), "a dead daemon must be restarted once its health check fails")
    }

    // MARK: - forceRestart(command:)

    @Test
    func forceRestartThrowsForUnknownCommand() async {
        let supervisor = LspSupervisor<FakeLanguageServerConnection>(
            workspaceRoot: Self.workspaceRoot,
            clock: ManualClock(),
            connectionFactory: fakeConnectionFactory(pid: 1, processState: ProcessState())
        )

        await #expect(throws: CodeContextError.self) {
            try await supervisor.forceRestart(command: "nonexistent-command")
        }
    }

    @Test
    func forceRestartDelegatesToTheManagedDaemon() async throws {
        let clock = ManualClock()
        let processState = ProcessState()
        let daemon = LSPDaemon<FakeLanguageServerConnection>(
            spec: Self.serverSpec(command: "true"),
            workspaceRoot: Self.workspaceRoot,
            clock: clock,
            connectionFactory: fakeConnectionFactory(pid: 9, processState: processState)
        )
        try await daemon.start()
        await processState.setAlive(false)
        _ = await daemon.healthCheck()
        let stateBeforeRestart = await daemon.state()
        guard case .failed = stateBeforeRestart else {
            Issue.record("expected .failed before force restart, got \(stateBeforeRestart)")
            return
        }

        let supervisor = LspSupervisor<FakeLanguageServerConnection>(
            workspaceRoot: Self.workspaceRoot,
            clock: clock,
            connectionFactory: fakeConnectionFactory(pid: 9, processState: processState)
        )
        await supervisor.insertDaemonForTesting(spec: Self.serverSpec(command: "true"), daemon: daemon)

        await processState.setAlive(true)
        try await supervisor.forceRestart(command: "true")

        let stateAfterRestart = await daemon.state()
        #expect(stateAfterRestart == .running(pid: 9))
    }

    // MARK: - shutdown()

    @Test
    func shutdownConcurrentlyTearsDownEveryManagedDaemonAndPreservesEntries() async throws {
        let clock = ManualClock()
        let processStateA = ProcessState()
        let processStateB = ProcessState()
        let daemonA = LSPDaemon<FakeLanguageServerConnection>(
            spec: Self.serverSpec(command: "true"),
            workspaceRoot: Self.workspaceRoot,
            clock: clock,
            connectionFactory: fakeConnectionFactory(pid: 1, processState: processStateA)
        )
        let daemonB = LSPDaemon<FakeLanguageServerConnection>(
            spec: Self.serverSpec(command: "false"),
            workspaceRoot: Self.workspaceRoot,
            clock: clock,
            connectionFactory: fakeConnectionFactory(pid: 2, processState: processStateB)
        )
        try await daemonA.start()
        try await daemonB.start()

        let supervisor = LspSupervisor<FakeLanguageServerConnection>(
            workspaceRoot: Self.workspaceRoot,
            clock: clock,
            connectionFactory: fakeConnectionFactory(pid: 0, processState: ProcessState())
        )
        await supervisor.insertDaemonForTesting(spec: Self.serverSpec(command: "true"), daemon: daemonA)
        await supervisor.insertDaemonForTesting(spec: Self.serverSpec(command: "false"), daemon: daemonB)

        await supervisor.shutdown()

        let statuses = await supervisor.status()
        #expect(statuses.count == 2, "shutdown must preserve managed daemon entries")
        #expect(statuses.allSatisfy { $0.state == .notStarted })
    }

    @Test
    func shutdownRacingAnInFlightRestartHandshakeAlwaysWinsAndLeavesTheDaemonNotStarted() async throws {
        let clock = ManualClock()
        let deadProcess = ProcessState()
        let deadSpec = Self.serverSpec(command: "false", healthCheckInterval: .seconds(30))

        // The restart's connection (the second one `gatedFactory` builds) is gated shut, so once
        // its handshake begins, `initialize()` suspends on a bare `CheckedContinuation` — a
        // primitive that, unlike `ManualClock.sleep`, does *not* observe task cancellation. This
        // models an in-flight actor call `shutdown()` genuinely cannot interrupt by cancelling,
        // only by awaiting its actual completion.
        let connectionIndex = Counter()
        let latestGate = Box<RestartGate?>(nil)
        let gatedFactory: ConnectionFactory<GatedConnection> = { _, _ in
            let index = await connectionIndex.increment()
            let gate = RestartGate()
            if index > 1 {
                await gate.close()
            }
            await latestGate.set(gate)
            return ConnectionHandle(
                connection: GatedConnection(gate: gate),
                pid: 2,
                isAlive: { await deadProcess.isAlive },
                waitForExit: { await deadProcess.waitForExit() },
                terminate: { await deadProcess.markTerminated() }
            )
        }

        let deadDaemon = LSPDaemon<GatedConnection>(
            spec: deadSpec,
            workspaceRoot: Self.workspaceRoot,
            clock: clock,
            connectionFactory: gatedFactory
        )
        try await deadDaemon.start()

        let supervisor = LspSupervisor<GatedConnection>(
            workspaceRoot: Self.workspaceRoot,
            clock: clock,
            connectionFactory: gatedFactory
        )
        await supervisor.insertDaemonForTesting(spec: deadSpec, daemon: deadDaemon)

        await deadProcess.setAlive(false)

        // Release the first health-check tick: the daemon crashes and the health loop begins its
        // backoff sleep before attempting a restart.
        await clock.waitForWaiter()
        clock.advance(by: .seconds(30))

        // Release the backoff delay: restartWithBackoff() calls start() again, creating the
        // gate-closed connection above.
        await clock.waitForWaiter()
        clock.advance(by: .seconds(2))

        // Wait for the handshake's own timeout-sleep to register — confirms `performHandshake` is
        // now racing the gated `initialize()` against its timeout, i.e. the restart is genuinely in
        // flight and stuck on an uncancellable primitive, not merely dispatched.
        await clock.waitForWaiter()

        // Race shutdown() against the still-in-flight restart handshake.
        let shutdownTask = Task { await supervisor.shutdown() }

        // Let shutdown()'s cancellation actually propagate before releasing the handshake, so the
        // race is genuine rather than trivially sequential.
        try await Task.sleep(for: .milliseconds(20))

        // Release the gated handshake so the in-flight restart (and therefore the health-loop
        // task, and therefore shutdown()) can finally resolve.
        let gate = await latestGate.value
        await gate?.open()

        await shutdownTask.value

        // A fixed real-time settle window, not a "wait until notStarted" poll: under a buggy
        // `shutdown()` that fires `cancel()` without awaiting the health-loop task, the daemon can
        // pass through `.notStarted` *transiently* (set by a reentrant `daemon.shutdown()` call
        // that ran while `start()` was still suspended on the gate) before the delayed, in-flight
        // restart's own failure handling overwrites it to `.failed` moments later. Polling for
        // "notStarted" would catch that transient value and declare victory too early; waiting a
        // fixed window instead lets any such delayed corruption actually land before we check.
        try? await Task.sleep(for: .milliseconds(200))

        let state = await deadDaemon.state()
        #expect(
            state == .notStarted,
            "a shutdown racing an in-flight restart handshake must win: the daemon must not be left running or failed instead of torn down"
        )
    }

    // MARK: - Auto-install

    /// Builds a `ServerSpec` whose `command` is not resolvable anywhere so `LSPDaemon.start()`
    /// lands `.notFound` on the initial spawn, carrying an `InstallSpec` for `installerTool`
    /// (`"true"` by default — a real, near-instant, always-present Unix utility, so
    /// `BinaryLookup.isOnPath(installer.tool)`'s real filesystem check inside
    /// `ServerInstaller.install(spec:)` always passes) with `extraSearchDirectories` pointing at
    /// `installDirectory` — the directory a scripted `FakeInstallRunner.setOnRun` closure
    /// materializes the fake binary into on a simulated "successful" install.
    private static func autoInstallSpec(
        command: String,
        installDirectory: URL,
        installerTool: String = "true"
    ) -> ServerSpec {
        ServerSpec(
            command: command,
            languageIDs: ["fake"],
            healthCheckInterval: .seconds(60),
            installHint: "install \(command) via \(installerTool)",
            installer: ServerSpec.InstallSpec(tool: installerTool, extraSearchDirectories: [installDirectory.path])
        )
    }

    /// Creates a chmod +x, zero-byte fake executable named `command` inside `directory`, mirroring
    /// `LSPDaemonTests`' own extra-search-directory fixtures — the technique a `FakeInstallRunner`
    /// success closure uses to simulate a real installer's on-disk side effect.
    private static func materializeFakeBinary(named command: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binaryPath = directory.appendingPathComponent(command)
        FileManager.default.createFile(atPath: binaryPath.path, contents: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath.path)
    }

    @Test
    func autoInstallSuccessTransitionsNotFoundToInstallingToRunning() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let command = "fake-auto-install-success-\(UUID().uuidString)"
        let spec = Self.autoInstallSpec(command: command, installDirectory: tempDirectory)

        let runner = FakeInstallRunner()
        await runner.setOnRun { _, _ in
            try? Self.materializeFakeBinary(named: command, in: tempDirectory)
        }

        let supervisor = LspSupervisor<FakeLanguageServerConnection>(
            workspaceRoot: Self.workspaceRoot,
            clock: ManualClock(),
            installRunner: runner,
            connectionFactory: fakeConnectionFactory(pid: 42, processState: ProcessState())
        )

        await supervisor.startForTesting(specs: [spec])

        // Assert the observable state sequence via status(): the daemon must have actually passed
        // through `.installing` (not merely landed `.running` some other way) before settling.
        await Self.waitUntil {
            let statuses = await supervisor.status()
            return statuses.first { $0.command == command }?.state != .notFound
        }
        let installingStatuses = await supervisor.status()
        #expect(
            installingStatuses.first { $0.command == command }?.state == .installing,
            "expected the daemon to be observably .installing while the fake install is in flight"
        )

        await Self.waitUntil {
            let statuses = await supervisor.status()
            if case .running = statuses.first(where: { $0.command == command })?.state { return true }
            return false
        }

        let finalStatuses = await supervisor.status()
        guard case .running = finalStatuses.first(where: { $0.command == command })?.state else {
            Issue.record("expected .running after a successful auto-install, got \(finalStatuses)")
            return
        }

        let invocations = await runner.invocations
        #expect(invocations.count == 1, "the installer must run at most once")
    }

    @Test
    func autoInstallFailureTransitionsInstallingBackToNotFoundWithoutRetry() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let command = "fake-auto-install-failure-\(UUID().uuidString)"
        let spec = Self.autoInstallSpec(command: command, installDirectory: tempDirectory)

        let runner = FakeInstallRunner()
        await runner.updateResult(.success(InstallRunResult(exitCode: 1, output: "boom")))

        let supervisor = LspSupervisor<FakeLanguageServerConnection>(
            workspaceRoot: Self.workspaceRoot,
            clock: ManualClock(),
            installRunner: runner,
            connectionFactory: fakeConnectionFactory(pid: 42, processState: ProcessState())
        )

        await supervisor.startForTesting(specs: [spec])

        await Self.waitUntil {
            let statuses = await supervisor.status()
            return statuses.first { $0.command == command }?.state == .installing
        }

        // The restart re-runs the binary lookup, which still finds nothing (the fake install never
        // materialized a binary), so the daemon must re-land .notFound rather than staying stuck
        // in .installing or ending up .failed.
        await Self.waitUntil {
            let statuses = await supervisor.status()
            return statuses.first { $0.command == command }?.state == .notFound
        }

        let finalState = await supervisor.status().first { $0.command == command }?.state
        #expect(finalState == .notFound)

        let invocations = await runner.invocations
        #expect(invocations.count == 1, "a failed install must never be retried")
    }

    @Test
    func autoInstallDisabledPolicyLeavesDaemonNotFoundWithoutInvokingRunner() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let command = "fake-auto-install-disabled-\(UUID().uuidString)"
        let spec = Self.autoInstallSpec(command: command, installDirectory: tempDirectory)

        let runner = FakeInstallRunner()
        let supervisor = LspSupervisor<FakeLanguageServerConnection>(
            workspaceRoot: Self.workspaceRoot,
            clock: ManualClock(),
            autoInstall: LspAutoInstall(isEnabled: false),
            installRunner: runner,
            connectionFactory: fakeConnectionFactory(pid: 42, processState: ProcessState())
        )

        await supervisor.startForTesting(specs: [spec])

        // A fixed settle window rather than a "wait until" poll: there is nothing to wait *for*
        // here (no install task is ever created), so this asserts the daemon never leaves
        // .notFound within a window that would easily have caught a regression.
        try await Task.sleep(for: .milliseconds(100))

        let state = await supervisor.status().first { $0.command == command }?.state
        #expect(state == .notFound, "a disabled auto-install policy must leave the daemon .notFound, exactly today's behavior")

        let invocations = await runner.invocations
        #expect(invocations.isEmpty, "a disabled policy must never invoke the runner")
    }

    @Test
    func autoInstallNilInstallerLeavesDaemonNotFoundWithoutInvokingRunner() async throws {
        let command = "fake-auto-install-nil-installer-\(UUID().uuidString)"
        let spec = ServerSpec(command: command, languageIDs: ["fake"], installHint: "install it by hand")

        let runner = FakeInstallRunner()
        let supervisor = LspSupervisor<FakeLanguageServerConnection>(
            workspaceRoot: Self.workspaceRoot,
            clock: ManualClock(),
            installRunner: runner,
            connectionFactory: fakeConnectionFactory(pid: 42, processState: ProcessState())
        )

        await supervisor.startForTesting(specs: [spec])
        try await Task.sleep(for: .milliseconds(100))

        let state = await supervisor.status().first { $0.command == command }?.state
        #expect(state == .notFound, "a spec with no installer must leave the daemon .notFound, exactly today's behavior")

        let invocations = await runner.invocations
        #expect(invocations.isEmpty, "a nil installer must never invoke the runner")
    }

    @Test
    func startForTestingReturnsWithDaemonAlreadyObservablyInstalling() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let command = "fake-auto-install-nonblocking-\(UUID().uuidString)"
        let spec = Self.autoInstallSpec(command: command, installDirectory: tempDirectory)

        // Gate the runner so the install never completes during this test — proving
        // `startForTesting`/`start()` returns without waiting for the install to finish.
        let runner = FakeInstallRunner()
        await runner.closeGate()

        let supervisor = LspSupervisor<FakeLanguageServerConnection>(
            workspaceRoot: Self.workspaceRoot,
            clock: ManualClock(),
            installRunner: runner,
            connectionFactory: fakeConnectionFactory(pid: 42, processState: ProcessState())
        )

        await supervisor.startForTesting(specs: [spec])

        // No settling/polling here on purpose: the assertion is about the state immediately after
        // `startForTesting` returns, not eventually.
        let state = await supervisor.status().first { $0.command == command }?.state
        #expect(
            state == .installing,
            "start() must return with an affected daemon already reporting .installing, with no settled .notFound flicker window"
        )

        await runner.openGate()
        await supervisor.shutdown()
    }

    @Test
    func shutdownDuringInFlightInstallCancelsCleanlyAndPromptly() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let command = "fake-auto-install-shutdown-\(UUID().uuidString)"
        let spec = Self.autoInstallSpec(command: command, installDirectory: tempDirectory)

        // Gates the runner so the install stays in flight until this test explicitly releases it.
        // `ServerInstaller.install(spec:)`'s in-flight `Task` is intentionally unstructured and
        // keeps running to completion regardless of a caller's own cancellation (see its own doc
        // comment) — so `shutdown()`'s cancel-then-await of the install task can only resolve once
        // this gate opens, mirroring exactly how `shutdownRacingAnInFlightRestartHandshakeAlwaysWinsAndLeavesTheDaemonNotStarted`
        // above races `shutdown()` against a gated handshake. What this test actually proves is
        // that once the gate opens, `shutdown()` still resolves promptly (bounded wall-clock, no
        // leaked task) and the guarded `forceRestart()` never fires afterward — the daemon is torn
        // down, not resurrected by the install that "completed" concurrently with/after shutdown.
        let runner = FakeInstallRunner()
        await runner.closeGate()

        let supervisor = LspSupervisor<FakeLanguageServerConnection>(
            workspaceRoot: Self.workspaceRoot,
            clock: ManualClock(),
            installRunner: runner,
            connectionFactory: fakeConnectionFactory(pid: 42, processState: ProcessState())
        )

        await supervisor.startForTesting(specs: [spec])
        await Self.waitUntil {
            let statuses = await supervisor.status()
            return statuses.first { $0.command == command }?.state == .installing
        }

        // Race shutdown() against the still-gated install.
        let start = ContinuousClock.now
        let shutdownTask = Task { await supervisor.shutdown() }

        // Let shutdown()'s cancellation actually propagate before releasing the gate, so the race
        // is genuine rather than trivially sequential.
        try await Task.sleep(for: .milliseconds(20))
        await runner.openGate()

        await shutdownTask.value
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(5), "shutdown() must resolve promptly once the gated install completes, took \(elapsed)")

        // A fixed real-time settle window (mirroring the handshake-race test above), not a
        // "wait until notStarted" poll: this catches a buggy `shutdown()` that returned before the
        // install task's guarded `forceRestart()` could ever fire, which would otherwise let a
        // delayed resurrection land after this assertion instead of before it.
        try await Task.sleep(for: .milliseconds(100))

        let stateAfterSettling = await supervisor.status().first { $0.command == command }?.state
        #expect(
            stateAfterSettling == .notStarted,
            "no post-shutdown state transition must occur once the gated install finally resolves, got \(String(describing: stateAfterSettling))"
        )
    }
}

/// A one-shot gate an async caller can wait on and a test can later release, using a bare
/// `CheckedContinuation` with no cancellation handling — unlike `ManualClock.sleep`, cancelling the
/// waiting task does *not* interrupt `waitUntilOpen()`. Models an in-flight actor call that
/// genuinely cannot be interrupted by cancellation alone.
private actor RestartGate {
    /// Whether the gate currently lets `waitUntilOpen()` return immediately.
    private var isOpen = true

    /// The suspended `waitUntilOpen()` caller's continuation, if the gate is currently closed.
    private var continuation: CheckedContinuation<Void, Never>?

    /// Closes the gate, so the next `waitUntilOpen()` call suspends until `open()` is called.
    func close() {
        isOpen = false
    }

    /// Suspends until the gate is open, returning immediately if it already is.
    func waitUntilOpen() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    /// Opens the gate, resuming a suspended `waitUntilOpen()` caller if there is one.
    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

/// A `LanguageServerConnection` whose `initialize(rootURI:)` suspends on a `RestartGate` before
/// forwarding to an inner `FakeLanguageServerConnection`. Every other requirement forwards
/// directly, mirroring `LSPDaemonTests`' `HangingInitializeConnection`.
private actor GatedConnection: LanguageServerConnection {
    private let inner = FakeLanguageServerConnection()
    private let gate: RestartGate

    /// Creates a connection whose handshake suspends on `gate`.
    /// - Parameter gate: The gate `initialize(rootURI:)` waits on before proceeding.
    init(gate: RestartGate) {
        self.gate = gate
    }

    nonisolated var serverNotifications: AsyncStream<ServerNotification> { inner.serverNotifications }

    func initialize(rootURI: DocumentURI?) async throws {
        await gate.waitUntilOpen()
        try await inner.initialize(rootURI: rootURI)
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
