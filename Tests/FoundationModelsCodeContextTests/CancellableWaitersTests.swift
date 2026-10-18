import Testing

@testable import FoundationModelsCodeContext

/// Unit tests for `CancellableWaiters` (`Sources/FoundationModelsCodeContext/LSP/CancellableWaiters.swift`),
/// the shared cancellable waiter that `ProcessGroupChild` uses to wait for the reap of its child.
///
/// Each test uses a `Bool` state that satisfies a wait when it is `true`. A wait that does not
/// return makes the test fail at the time limit, and does not stop the suite.
struct CancellableWaitersTests {
    /// Makes waiters whose state satisfies a wait when the state is `true`.
    /// - Parameter isSet: The initial state.
    /// - Returns: The waiters.
    private static func makeFlagWaiters(isSet: Bool) -> CancellableWaiters<Bool> {
        CancellableWaiters(isSet) { isSet in isSet }
    }

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func readGivesTheInitialState() {
        let waiters = Self.makeFlagWaiters(isSet: true)

        #expect(waiters.read { isSet in isSet })
    }

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func updateChangesTheStateThatReadGives() {
        let waiters = Self.makeFlagWaiters(isSet: false)

        waiters.update { isSet in isSet = true }

        #expect(waiters.read { isSet in isSet })
    }

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func waitReturnsAtOnceWhenTheStateIsAlreadySatisfied() async {
        let waiters = Self.makeFlagWaiters(isSet: true)

        await waiters.wait()

        #expect(waiters.read { isSet in isSet })
    }

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func updateThatSatisfiesTheStateResumesEachWait() async {
        let waiters = Self.makeFlagWaiters(isSet: false)

        async let firstWait: Void = waiters.wait()
        async let secondWait: Void = waiters.wait()
        waiters.update { isSet in isSet = true }
        _ = await (firstWait, secondWait)

        #expect(waiters.read { isSet in isSet })
    }

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func waitReturnsWhenItsTaskWasCancelledBeforeTheWaitStarted() async {
        let waiters = Self.makeFlagWaiters(isSet: false)

        let task = Task {
            withUnsafeCurrentTask { task in task?.cancel() }
            await waiters.wait()
        }
        await task.value

        #expect(!waiters.read { isSet in isSet })
    }

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func waitReturnsWhenItsTaskIsCancelled() async {
        let waiters = Self.makeFlagWaiters(isSet: false)

        let task = Task { await waiters.wait() }
        task.cancel()
        await task.value

        #expect(!waiters.read { isSet in isSet })
    }
}
