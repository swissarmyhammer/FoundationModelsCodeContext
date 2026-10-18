import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// Tests for a `shutdown()` of `LspSupervisor` that comes while a spawn round runs.
///
/// The connection factory of each test waits at an `AsyncGate` before it gives a connection.
/// Thus the spawn round stays in progress while the test calls `shutdown()`. A cancel does not
/// stop the wait at the gate, thus the spawn round continues when the test opens the gate. No
/// real child process starts: each connection is a `FakeLanguageServerConnection`.
struct LspSupervisorShutdownDuringStartTests {
    /// The pid that the fake process of each daemon reports.
    private static let fakeServerPid: Int32 = 1

    /// The real time that a test waits for a task that it cannot observe directly, for example
    /// a `shutdown()` call that waits, or a health loop that a spawn round can start late.
    private static let settleWindow: Duration = .milliseconds(100)

    /// Makes a connection factory that waits at `gate` before it gives a fake connection.
    /// - Parameters:
    ///   - gate: The gate that each factory call waits at.
    ///   - arrivals: Counts the factory calls that came to the gate.
    ///   - processState: The liveness of the fake process of each connection.
    /// - Returns: The factory.
    private static func makeGatedConnectionFactory(
        gate: AsyncGate,
        arrivals: Counter,
        processState: ProcessState
    ) -> ConnectionFactory<FakeLanguageServerConnection> {
        let fakeFactory = fakeConnectionFactory(pid: fakeServerPid, processState: processState)
        return { spec, workspaceRoot in
            await arrivals.increment()
            await gate.waitUntilOpen()
            return try await fakeFactory(spec, workspaceRoot)
        }
    }

    /// Waits until the factory of a spawn round waits at its gate.
    /// - Parameter arrivals: Counts the factory calls that came to the gate.
    /// - Throws: `CancellationError` when the task of the test is cancelled.
    private static func waitForTheSpawnAtTheGate(arrivals: Counter) async throws {
        try await waitUntil { await arrivals.value > 0 }
    }

    /// Whether `statuses` holds a daemon that runs.
    /// - Parameter statuses: The statuses of the supervisor.
    /// - Returns: `true` when one status or more is `.running`.
    private static func hasARunningDaemon(_ statuses: [ServerStatus]) -> Bool {
        statuses.contains { status in
            if case .running = status.state {
                return true
            }
            return false
        }
    }

    /// A `shutdown()` during a `start()` whose connection waits waits for that start. After the
    /// `shutdown()` returns, no daemon runs, the fake process does not run, and no health loop
    /// sleeps on the clock.
    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func shutdownDuringAStartWhoseConnectionWaitsLeavesNoRunningDaemonAndNoHealthLoop() async throws {
        try await withTemporaryWorkspace { root in
            let clock = ManualClock()
            let gate = AsyncGate()
            let arrivals = Counter()
            let processState = ProcessState()
            let supervisor = LspSupervisor<FakeLanguageServerConnection>(
                workspaceRoot: root,
                clock: clock,
                autoInstall: LspAutoInstall(isEnabled: false),
                serverSpecs: { _ in [LspSupervisorTests.serverSpec()] },
                connectionFactory: Self.makeGatedConnectionFactory(gate: gate, arrivals: arrivals, processState: processState)
            )

            let start = Task { try await supervisor.start() }
            try await Self.waitForTheSpawnAtTheGate(arrivals: arrivals)
            let shutdown = Task { await supervisor.shutdown() }
            try await Task.sleep(for: Self.settleWindow)
            await gate.open()
            await shutdown.value
            let statusesAfterTheShutdown = await supervisor.status()
            _ = try? await start.value
            try await Task.sleep(for: Self.settleWindow)

            #expect(!Self.hasARunningDaemon(statusesAfterTheShutdown))
            #expect(!Self.hasARunningDaemon(await supervisor.status()))
            #expect(!(await processState.isAlive), "the process of the new daemon must not run after the shutdown")
            #expect(clock.waiterCount == 0, "no health loop may sleep on the clock after the shutdown")
        }
    }

    /// A spawn round whose connection arrives after a `shutdown()` completed does not register
    /// its daemon. It shuts the daemon down, thus the fake process does not run and no health
    /// loop sleeps on the clock.
    ///
    /// `startForTesting(specs:)` runs the spawn round of `start()` outside the in-flight start
    /// task, thus the `shutdown()` does not wait for it. Only the stop state of the supervisor
    /// stops the registration.
    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func aSpawnRoundThatEndsAfterAShutdownShutsItsDaemonDownAndDoesNotRegisterIt() async throws {
        let clock = ManualClock()
        let gate = AsyncGate()
        let arrivals = Counter()
        let processState = ProcessState()
        let supervisor = LspSupervisor<FakeLanguageServerConnection>(
            workspaceRoot: LspSupervisorTests.workspaceRoot,
            clock: clock,
            autoInstall: LspAutoInstall(isEnabled: false),
            connectionFactory: Self.makeGatedConnectionFactory(gate: gate, arrivals: arrivals, processState: processState)
        )

        let spawnRound = Task { await supervisor.startForTesting(specs: [LspSupervisorTests.serverSpec()]) }
        try await Self.waitForTheSpawnAtTheGate(arrivals: arrivals)
        await supervisor.shutdown()
        await gate.open()
        await spawnRound.value
        try await Task.sleep(for: Self.settleWindow)

        #expect(await supervisor.status().isEmpty, "a daemon that a spawn round makes after a shutdown must not be registered")
        #expect(!(await processState.isAlive), "the process of the new daemon must not run after the shutdown")
        #expect(clock.waiterCount == 0, "no health loop may sleep on the clock after the shutdown")
    }
}
