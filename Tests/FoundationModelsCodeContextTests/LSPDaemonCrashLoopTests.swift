import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// Tests for the failure count of `LSPDaemon` when a server crashes again and again: a good
/// handshake does not set the count to zero, thus a crash loop after `initialize` stops at the
/// failure limit with a longer backoff each time. Only a health check after the minimum healthy
/// uptime gives the server its full restart budget again.
///
/// The tests are in an extension of `LSPDaemonTests`, thus they use its fixtures `serverSpec()`
/// and `workspaceRoot`.
extension LSPDaemonTests {
    /// The number of seconds in `crashLoopMinimumHealthyUptime`.
    private static let crashLoopMinimumHealthyUptimeSeconds = 10

    /// The minimum healthy uptime of the crash loop tests. It is short, thus one advance of the
    /// clock gives a process that uptime.
    private static let crashLoopMinimumHealthyUptime: Duration = .seconds(crashLoopMinimumHealthyUptimeSeconds)

    /// The backoff delay, in seconds, of the restart after the first failure.
    private static let firstBackoffDelaySeconds: Int64 = 2

    /// The backoff delays of the restarts after one, two, three and four consecutive failures
    /// (2, 4, 8 and 16 seconds): each delay is two times the delay before it.
    private static let crashLoopBackoffDelays: [Duration] = (0..<(consecutiveFailureLimit - 1)).map {
        .seconds(firstBackoffDelaySeconds << $0)
    }

    /// The number of consecutive failures after which `restartWithBackoff()` stops.
    private static let consecutiveFailureLimit = 5

    /// The pid of the fake process of the crash loop tests.
    private static let crashLoopPid: Int32 = 11

    /// Builds a daemon for the tests of a server that crashes again and again. `processState`
    /// tells whether the process is alive.
    ///
    /// Not private: the "gives up" warning tests in `LspSupervisorGivingUpTests.swift` use it too.
    /// - Parameters:
    ///   - clock: The clock of the backoff delays and of the uptime.
    ///   - processState: The liveness of the fake process.
    ///   - configureConnection: Called with each new fake connection before the handshake, thus a
    ///     test can make the handshake fail. Defaults to no change: each handshake succeeds.
    /// - Returns: A daemon with `crashLoopMinimumHealthyUptime` as its minimum healthy uptime.
    static func crashLoopDaemon(
        clock: ManualClock,
        processState: ProcessState,
        configureConnection: @escaping @Sendable (FakeLanguageServerConnection) async -> Void = { _ in }
    ) -> LSPDaemon<FakeLanguageServerConnection> {
        LSPDaemon<FakeLanguageServerConnection>(
            spec: serverSpec(),
            workspaceRoot: workspaceRoot,
            clock: clock,
            minimumHealthyUptime: crashLoopMinimumHealthyUptime,
            connectionFactory: fakeConnectionFactory(
                pid: crashLoopPid,
                processState: processState,
                configureConnection: configureConnection
            )
        )
    }

    /// Makes the fake process exit, and lets one health check find the exit.
    /// - Parameters:
    ///   - daemon: The daemon that runs the process.
    ///   - processState: The liveness of the fake process.
    /// - Returns: The attempt count of the `.failed` state, or `nil` when the state is not `.failed`.
    private static func crash(
        _ daemon: LSPDaemon<FakeLanguageServerConnection>,
        processState: ProcessState
    ) async -> Int? {
        await processState.setAlive(false)
        await daemon.healthCheck()
        guard case .failed(_, let attempts) = await daemon.state() else { return nil }
        return attempts
    }

    /// Restarts `daemon` with `restartWithBackoff()`, and releases its backoff sleep only when
    /// the sleep has exactly `delay` as its length.
    ///
    /// A different delay leaves the restart waiting, and the time limit of the test stops it.
    /// - Parameters:
    ///   - daemon: The daemon in `.failed`.
    ///   - clock: The clock of the backoff sleep.
    ///   - processState: The liveness of the fake process. The new process is alive.
    ///   - delay: The backoff delay that the restart must use.
    private static func restart(
        _ daemon: LSPDaemon<FakeLanguageServerConnection>,
        clock: ManualClock,
        processState: ProcessState,
        afterExactly delay: Duration
    ) async {
        await processState.setAlive(true)
        let deadline = clock.now.advanced(by: delay)
        let restartTask = Task { try? await daemon.restartWithBackoff() }
        await clock.waitForWaiter(withDeadline: deadline)
        clock.advance(by: delay)
        await restartTask.value
    }

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func aServerThatCrashesRightAfterInitializeStopsAtTheFailureLimitWithALongerBackoffEachTime() async throws {
        let clock = ManualClock()
        let processState = ProcessState()
        let daemon = Self.crashLoopDaemon(clock: clock, processState: processState)

        try await daemon.start()
        var attempts = await Self.crash(daemon, processState: processState)

        for (index, delay) in Self.crashLoopBackoffDelays.enumerated() {
            try #require(attempts == index + 1, "a good handshake must not reset the failure count")
            await Self.restart(daemon, clock: clock, processState: processState, afterExactly: delay)
            #expect(await daemon.state() == .running(pid: Self.crashLoopPid))
            // A health check finds the new process alive, but its uptime is shorter than the
            // minimum healthy uptime. Thus the failure count stays.
            await daemon.healthCheck()
            attempts = await Self.crash(daemon, processState: processState)
        }

        #expect(attempts == Self.consecutiveFailureLimit)
        await #expect(throws: CodeContextError.self) {
            try await daemon.restartWithBackoff()
        }
    }

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func aServerThatRunsForTheMinimumHealthyUptimeGetsItsFullRestartBudgetAgain() async throws {
        let clock = ManualClock()
        let processState = ProcessState()
        let daemon = Self.crashLoopDaemon(clock: clock, processState: processState)
        let firstDelay = try #require(Self.crashLoopBackoffDelays.first)

        try await daemon.start()
        #expect(await Self.crash(daemon, processState: processState) == 1)
        await Self.restart(daemon, clock: clock, processState: processState, afterExactly: firstDelay)

        clock.advance(by: Self.crashLoopMinimumHealthyUptime)
        #expect(await daemon.healthCheck())

        #expect(
            await Self.crash(daemon, processState: processState) == 1,
            "a crash after a healthy uptime must start a new failure count"
        )
        await Self.restart(daemon, clock: clock, processState: processState, afterExactly: firstDelay)
        #expect(await daemon.state() == .running(pid: Self.crashLoopPid))
    }
}
