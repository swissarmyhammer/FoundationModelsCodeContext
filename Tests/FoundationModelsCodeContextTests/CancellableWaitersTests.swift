import Testing

@testable import FoundationModelsCodeContext

/// Unit tests for `CancellableWaiters` (`Sources/FoundationModelsCodeContext/LSP/CancellableWaiters.swift`),
/// the shared cancellable waiter. `ProcessGroupChild` uses it to wait for the reap of its child, and
/// `UpdateMailbox` uses it to wait for the next diagnostics update.
///
/// Each test uses `CancellableWaiters.flag(isSet:)`: a `Bool` state that satisfies a wait when it
/// is `true`. A wait that does not return makes the test fail at the time limit, and does not stop
/// the suite.
struct CancellableWaitersTests {
    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func readGivesTheInitialState() {
        let waiters = CancellableWaiters.flag(isSet: true)

        #expect(waiters.read { isSet in isSet })
    }

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func updateChangesTheStateThatReadGives() {
        let waiters = CancellableWaiters.flag(isSet: false)

        waiters.update { isSet in isSet = true }

        #expect(waiters.read { isSet in isSet })
    }

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func updateGivesTheValueThatItsChangeReturns() {
        let waiters = CancellableWaiters.flag(isSet: false)

        let stateBeforeTheChange = waiters.update { isSet in
            defer { isSet = true }
            return isSet
        }

        #expect(!stateBeforeTheChange)
        #expect(waiters.read { isSet in isSet })
    }

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func waitReturnsAtOnceWhenTheStateIsAlreadySatisfied() async {
        let waiters = CancellableWaiters.flag(isSet: true)

        await waiters.wait()

        #expect(waiters.read { isSet in isSet })
    }

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func updateThatSatisfiesTheStateResumesEachWait() async {
        let waiters = CancellableWaiters.flag(isSet: false)

        async let firstWait: Void = waiters.wait()
        async let secondWait: Void = waiters.wait()
        waiters.update { isSet in isSet = true }
        _ = await (firstWait, secondWait)

        #expect(waiters.read { isSet in isSet })
    }

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func waitReturnsWhenItsTaskWasCancelledBeforeTheWaitStarted() async {
        let waiters = CancellableWaiters.flag(isSet: false)

        let task = Task {
            withUnsafeCurrentTask { task in task?.cancel() }
            await waiters.wait()
        }
        await task.value

        #expect(!waiters.read { isSet in isSet })
    }

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func waitReturnsWhenItsTaskIsCancelled() async {
        let waiters = CancellableWaiters.flag(isSet: false)

        let task = Task { await waiters.wait() }
        task.cancel()
        await task.value

        #expect(!waiters.read { isSet in isSet })
    }
}
