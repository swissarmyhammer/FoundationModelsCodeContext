import Testing

@testable import FoundationModelsCodeContext

/// Unit tests for `UpdateMailbox` (`Sources/FoundationModelsCodeContext/Diagnostics/UpdateMailbox.swift`),
/// the cancellable notifier that `Settle.race(...)` uses to wait for the next diagnostics update.
///
/// `UpdateMailbox` keeps its state in a `CancellableWaiters`. `next()` has no check of its own
/// before the wait: it always calls `CancellableWaiters.wait()`, and the registration of that wait
/// reads the state while the lock is held. Thus a `record(_:)` or a `markClosed()` before the wait
/// registers is the same as a `record(_:)` or a `markClosed()` before `next()`, and these tests
/// make that race occur on each run. Task `^vhcye6y` found this race: under load, it caused a
/// full-suite hang in `DiagnosticsTests.updateAtT200RestartsQuiescenceWindowSoSettleFiresAtT500NotT300()`.
///
/// A wait that does not return makes the test fail at the time limit, and does not stop the suite.
struct UpdateMailboxTests {
    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func recordWhileNextWaitsEndsTheWaitWithTheUpdate() async {
        let mailbox = UpdateMailbox()
        let update = DiagnosticUpdate(uri: DocumentURI("file:///a.swift"), diagnostics: [])

        async let event = mailbox.next()
        mailbox.record(update)

        #expect(await event == .updates([update]))
    }

    /// The regression case: the background task of `Settle.settleStream` can call `record(_:)`
    /// before the wait of `next()` registers. The registration must see the update and end the
    /// wait at once. If it does not, only a cancel of the whole race can end the wait.
    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func recordBeforeTheWaitRegistersStillEndsTheWait() async {
        let mailbox = UpdateMailbox()
        let update = DiagnosticUpdate(uri: DocumentURI("file:///b.swift"), diagnostics: [])

        mailbox.record(update)
        let event = await mailbox.next()

        #expect(event == .updates([update]))
    }

    /// The same regression for `markClosed()`: the end of the stream before the wait registers
    /// must also end the wait.
    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func markClosedBeforeTheWaitRegistersEndsTheWaitWithClosed() async {
        let mailbox = UpdateMailbox()

        mailbox.markClosed()
        let event = await mailbox.next()

        #expect(event == .closed)
    }

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func markClosedWhileNextWaitsEndsTheWaitWithClosed() async {
        let mailbox = UpdateMailbox()

        async let event = mailbox.next()
        mailbox.markClosed()

        #expect(await event == .closed)
    }

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func nextEmptiesTheQueueThusTheNextCallGivesOnlyNewUpdates() async {
        let mailbox = UpdateMailbox()
        let firstUpdate = DiagnosticUpdate(uri: DocumentURI("file:///c.swift"), diagnostics: [])
        let secondUpdate = DiagnosticUpdate(uri: DocumentURI("file:///d.swift"), diagnostics: [])
        mailbox.record(firstUpdate)
        _ = await mailbox.next()

        mailbox.record(secondUpdate)
        let event = await mailbox.next()

        #expect(event == .updates([secondUpdate]))
    }

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func queuedUpdatesComeBeforeTheClose() async {
        let mailbox = UpdateMailbox()
        let update = DiagnosticUpdate(uri: DocumentURI("file:///e.swift"), diagnostics: [])
        mailbox.record(update)
        mailbox.markClosed()

        let firstEvent = await mailbox.next()
        let secondEvent = await mailbox.next()

        #expect(firstEvent == .updates([update]))
        #expect(secondEvent == .closed)
    }

    @Test(.timeLimit(.minutes(testTimeLimitMinutes)))
    func nextReturnsNoUpdatesWhenItsTaskIsCancelled() async {
        let mailbox = UpdateMailbox()

        let task = Task {
            withUnsafeCurrentTask { task in task?.cancel() }
            return await mailbox.next()
        }

        #expect(await task.value == .updates([]))
    }
}
