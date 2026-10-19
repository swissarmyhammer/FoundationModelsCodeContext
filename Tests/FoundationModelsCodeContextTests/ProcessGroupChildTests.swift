import Darwin
import Testing

@testable import FoundationModelsCodeContext

/// Unit tests for the order of the group signals and the reap in `ProcessGroupChild`
/// (`Sources/FoundationModelsCodeContext/LSP/ProcessGroupChild.swift`).
///
/// The child leads its own process group, thus its pid is also the id of the group. After the
/// reap of the child, the kernel can give that pid to a new process, which can lead a group of
/// its own, and a signal to `-pid` then reaches that unrelated group. So no group signal may come
/// after the reap: the child stays a zombie, which keeps its pid reserved, until no more group
/// signal can come.
///
/// Each test uses `RecordingProcessGroupCalls`, a fake with no real process that records each
/// signal and the reap in their order. The real process calls are tested by the process tests
/// of the callers (`ServerInstallerTests`, `ConnectionTests` and the integration package).
struct ProcessGroupChildTests {
    /// The pid of the fake leader. No call reaches a real process with it.
    private static let leaderPID: pid_t = 4242

    /// The grace of `terminateGroup(grace:)`. The fake leader exits at `SIGTERM`, thus no test
    /// waits this long.
    private static let terminationGrace: Duration = .seconds(30)

    /// The exit status of a fake leader that exits by itself.
    private static let exitStatus: Int32 = 3

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func terminateGroupSendsBothGroupSignalsBeforeTheReap() async {
        let calls = RecordingProcessGroupCalls(endingSignal: SIGTERM)
        let child = ProcessGroupChild(pid: Self.leaderPID, calls: calls)

        await child.terminateGroup(grace: Self.terminationGrace)

        #expect(calls.calls == [.signal(SIGTERM), .signal(SIGKILL), .reap])
    }

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func signalGroupAfterTerminateGroupSendsNoSignal() async {
        let calls = RecordingProcessGroupCalls(endingSignal: SIGTERM)
        let child = ProcessGroupChild(pid: Self.leaderPID, calls: calls)
        await child.terminateGroup(grace: Self.terminationGrace)

        child.signalGroup(SIGKILL)

        #expect(calls.calls == [.signal(SIGTERM), .signal(SIGKILL), .reap])
    }

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func anExitedChildStaysUnreapedWhileItCanStillBeSignalled() async {
        let calls = RecordingProcessGroupCalls()
        let child = ProcessGroupChild(pid: Self.leaderPID, calls: calls)

        calls.exit(status: Self.exitStatus)
        await child.waitUntilExit()

        #expect(!child.isRunning)
        #expect(calls.calls.isEmpty)
    }

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func aSignalAfterTheExitComesBeforeTheReapAtTheRelease() async {
        let calls = RecordingProcessGroupCalls()

        await Self.signalAfterTheExitAndRelease(calls)

        #expect(calls.calls == [.signal(SIGKILL), .reap])
    }

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func aChildReleasedBeforeItsExitIsReapedAtTheExit() async {
        let calls = RecordingProcessGroupCalls()
        Self.signalAndRelease(calls)

        calls.exit(status: SIGKILL)
        await calls.reaped.wait()

        #expect(calls.calls == [.signal(SIGKILL), .reap])
    }

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func terminationStatusIsTheStatusThatTheExitReported() async {
        let calls = RecordingProcessGroupCalls()
        let child = ProcessGroupChild(pid: Self.leaderPID, calls: calls)

        calls.exit(status: Self.exitStatus)

        #expect(await child.terminationStatus == Self.exitStatus)
    }

    /// Starts a child on `calls`, lets it exit, sends `SIGKILL` to its group, and releases it,
    /// as a `ProcessLanguageServerConnection` that is released with no `close()` does.
    /// - Parameter calls: The fake process calls.
    private static func signalAfterTheExitAndRelease(_ calls: RecordingProcessGroupCalls) async {
        let child = ProcessGroupChild(pid: leaderPID, calls: calls)
        calls.exit(status: exitStatus)
        await child.waitUntilExit()
        child.signalGroup(SIGKILL)
    }

    /// Starts a child on `calls`, sends `SIGKILL` to its group, and releases it before its exit.
    /// - Parameter calls: The fake process calls.
    private static func signalAndRelease(_ calls: RecordingProcessGroupCalls) {
        let child = ProcessGroupChild(pid: leaderPID, calls: calls)
        child.signalGroup(SIGKILL)
    }
}
