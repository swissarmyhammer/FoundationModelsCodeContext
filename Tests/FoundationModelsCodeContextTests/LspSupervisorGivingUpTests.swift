import Foundation
import InMemoryLogging
import Logging
import Testing

@testable import FoundationModelsCodeContext

/// Tests for the "gives up" warning of the health loop of `LspSupervisor`: when a daemon has
/// used its restart budget, the loop writes the warning one time, not at each interval.
///
/// The tests are in an extension of `LspSupervisorTests`, thus they use its fixtures
/// `serverSpec(command:healthCheckInterval:)`, `workspaceRoot` and `stateWaitTimeout`.
extension LspSupervisorTests {
    /// The number of seconds in `givingUpHealthCheckInterval`.
    private static let givingUpHealthCheckIntervalSeconds = 30

    /// The health check interval of the give-up test.
    private static let givingUpHealthCheckInterval: Duration = .seconds(givingUpHealthCheckIntervalSeconds)

    /// The number of seconds in `givingUpClockStep`.
    private static let givingUpClockStepSeconds = 120

    /// One advance of the clock in the give-up test. It is longer than the health check
    /// interval and the backoff cap, thus it releases each sleep of the health loop.
    private static let givingUpClockStep: Duration = .seconds(givingUpClockStepSeconds)

    /// The number of health check intervals that the give-up test lets pass after the first
    /// "gives up" warning.
    private static let givingUpExtraTicks = 3

    /// The pid of the fake process of the give-up test.
    private static let givingUpPid: Int32 = 12

    /// The text of the warning that the health loop writes when a daemon has no restart budget.
    private static let givingUpWarningText = "gives up"

    /// The "gives up" warnings of the health loop for `command`.
    /// - Parameter command: The command under which the supervisor manages the daemon.
    /// - Returns: The captured warnings that hold `givingUpWarningText` and name `command`.
    private static func givingUpWarnings(command: String) -> [InMemoryLogHandler.Entry] {
        CapturedLogRecords.entries(matching: [CodeContextTracing.MetadataKey.lspServer: command])
            .filter { $0.message.description.contains(givingUpWarningText) }
    }

    /// Lets one sleep of the health loop elapse: waits until the loop sleeps, then advances
    /// `clock` by `givingUpClockStep`.
    /// - Parameter clock: The clock of the health loop and of the daemon.
    private static func releaseOneSleep(of clock: ManualClock) async {
        await clock.waitForWaiter()
        clock.advance(by: givingUpClockStep)
    }

    /// Builds a started daemon whose process is dead and whose next handshakes fail, thus each
    /// restart of the health loop fails and the daemon uses all of its restart budget.
    /// - Parameter clock: The clock of the daemon.
    /// - Returns: The daemon, in `.running` with a dead process.
    private static func daemonThatFailsEachRestart(
        clock: ManualClock
    ) async throws -> LSPDaemon<FakeLanguageServerConnection> {
        let processState = ProcessState()
        let shouldFailHandshake = Box(false)
        let scriptedFailure = CodeContextError.handshakeFailed("scripted")
        let factory = fakeConnectionFactory(pid: givingUpPid, processState: processState) { connection in
            if await shouldFailHandshake.value {
                await connection.setInitializeResult(to: .failure(scriptedFailure))
            }
        }
        let daemon = LSPDaemon<FakeLanguageServerConnection>(
            spec: serverSpec(),
            workspaceRoot: workspaceRoot,
            clock: clock,
            connectionFactory: factory
        )
        try await daemon.start()
        await shouldFailHandshake.set(true)
        await processState.setAlive(false)
        return daemon
    }

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func healthLoopWritesTheGivingUpWarningOneTime() async throws {
        _ = CapturedLogRecords.handler
        let clock = ManualClock()
        let daemon = try await Self.daemonThatFailsEachRestart(clock: clock)

        // The supervisor names the daemon with a command that only this test uses, thus the
        // test finds only its own warnings.
        let command = "giving-up-\(UUID().uuidString)"
        let supervisor = LspSupervisor<FakeLanguageServerConnection>(
            workspaceRoot: Self.workspaceRoot,
            clock: clock,
            connectionFactory: fakeConnectionFactory(pid: Self.givingUpPid, processState: ProcessState())
        )
        await supervisor.insertDaemonForTesting(
            spec: Self.serverSpec(command: command, healthCheckInterval: Self.givingUpHealthCheckInterval),
            daemon: daemon
        )

        try await withAsyncCleanup {
            let gaveUp = try await waitUntil(timeout: Self.stateWaitTimeout) {
                await Self.releaseOneSleep(of: clock)
                return !Self.givingUpWarnings(command: command).isEmpty
            }
            #expect(gaveUp, "the health loop must write a warning when the daemon gives up")

            for _ in 0..<Self.givingUpExtraTicks {
                await Self.releaseOneSleep(of: clock)
            }
            // The loop sleeps again only after it completed the last health check.
            await clock.waitForWaiter()

            #expect(Self.givingUpWarnings(command: command).count == 1)
        } cleanup: {
            await supervisor.shutdown()
        }
    }
}
