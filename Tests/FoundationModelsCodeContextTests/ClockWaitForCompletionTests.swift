import Testing

@testable import FoundationModelsCodeContext

/// Unit tests for `Clock.waitForCompletion(atMost:_:)`
/// (`Sources/FoundationModelsCodeContext/LSP/Clock+WaitForCompletion.swift`), the shared race of an
/// operation against a time limit that `ProcessGroupChild` and `LSPDaemon.shutdown()` use.
///
/// Each test uses a `ManualClock`, thus the time limit elapses only at `advance(by:)`. The
/// operation that does not finish waits on `CancellableWaiters` whose state stays unsatisfied, thus
/// only a cancel ends it.
struct ClockWaitForCompletionTests {
    /// The number of seconds in `limit`.
    private static let limitSeconds = 5

    /// The time limit of each race.
    private static let limit: Duration = .seconds(limitSeconds)

    /// Makes waiters whose state never satisfies a wait.
    /// - Returns: The waiters.
    private static func makeNeverSatisfiedWaiters() -> CancellableWaiters<Bool> {
        CancellableWaiters(false) { isSet in isSet }
    }

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func returnsTrueWhenTheOperationFinishesBeforeTheLimit() async {
        let clock = ManualClock()

        let finishedFirst = await clock.waitForCompletion(atMost: Self.limit) {}

        #expect(finishedFirst)
    }

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func returnsFalseWhenTheLimitElapsesBeforeTheOperationFinishes() async {
        let clock = ManualClock()
        let neverSatisfied = Self.makeNeverSatisfiedWaiters()

        async let finishedFirst = clock.waitForCompletion(atMost: Self.limit) {
            await neverSatisfied.wait()
        }
        await clock.waitForWaiter()
        clock.advance(by: Self.limit)

        #expect(await finishedFirst == false)
    }

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func cancelsTheOperationWhenTheLimitElapses() async {
        let clock = ManualClock()
        let neverSatisfied = Self.makeNeverSatisfiedWaiters()
        let operationWasCancelled = Box(false)

        async let finishedFirst = clock.waitForCompletion(atMost: Self.limit) {
            await neverSatisfied.wait()
            await operationWasCancelled.set(Task.isCancelled)
        }
        await clock.waitForWaiter()
        clock.advance(by: Self.limit)
        _ = await finishedFirst

        #expect(await operationWasCancelled.value)
    }
}
