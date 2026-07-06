import Foundation
import Testing

@testable import CodeContextKit

/// Unit tests for `UpdateMailbox` (`Sources/CodeContextKit/Diagnostics/UpdateMailbox.swift`),
/// the cancellation-safe single-slot notifier `Settle.race(...)` uses to wait for the next
/// diagnostics update.
///
/// These are unit tests rather than integration tests through `Settle`/`DiagnosticsTests.swift`
/// because the bug they guard against is a scheduling race — `record(_:)`/`markClosed()` running
/// between `next()`'s own `takeQueuedIfAny()` miss and its subsequent `registerWaiter(token:continuation:)`
/// call — that only a direct, ordering-controlled call sequence can force deterministically. See
/// task `^vhcye6y`'s investigation: this exact race, manifesting only under heavy scheduling
/// pressure from hundreds of concurrently-running tests, caused a full-suite hang in
/// `DiagnosticsTests.swift`'s `updateAtT200RestartsQuiescenceWindowSoSettleFiresAtT500NotT300()`
/// that reproduced independently in two separate full-suite runs (a concurrent session's, and this
/// session's own) but never in isolation.
struct UpdateMailboxTests {
    @Test
    func registerThenRecordDeliversTheUpdateToTheContinuation() async throws {
        let mailbox = UpdateMailbox()
        let update = DiagnosticUpdate(uri: DocumentURI("file:///a.swift"), diagnostics: [])

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            mailbox.registerWaiter(token: 1, continuation: continuation)
            mailbox.record(update)
        }

        let event = await mailbox.next()
        #expect(event == .updates([update]))
    }

    /// The regression case: `record(_:)` can legitimately run — from the background stream-drain
    /// task in `Settle.settleStream` — *after* `next()`'s own `takeQueuedIfAny()` check already
    /// came up empty but *before* `registerWaiter(token:continuation:)` actually runs, because
    /// those are two separate steps with no ordering enforced between them (mirrors
    /// `ProcessLanguageServerConnection`'s `PendingRequestTable`, which has the identical shape
    /// for the identical reason). Before the `!queued.isEmpty || isClosed` check existed in
    /// `registerWaiter`, this would register the continuation anyway, orphaning it: only the
    /// entire `Settle.race(...)` `TaskGroup`'s eventual cancellation (from a sibling
    /// `Clock.sleep(until:)` branch winning) would ever wake it, and if that branch was itself
    /// starved of a chance to run under the same scheduling pressure that lost this race, the
    /// continuation hung forever.
    @Test
    func recordBeforeRegisterStillDeliversTheUpdateOnceRegistered() async throws {
        let mailbox = UpdateMailbox()
        let update = DiagnosticUpdate(uri: DocumentURI("file:///b.swift"), diagnostics: [])

        // The update arrives first — nothing has registered a waiter yet, exactly as if `next()`'s
        // `takeQueuedIfAny()` check had already missed and `registerWaiter` simply hadn't run yet.
        mailbox.record(update)

        // Registering afterward must still deliver the already-arrived update immediately, not
        // hang waiting for a resolution that has already happened.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            mailbox.registerWaiter(token: 2, continuation: continuation)
        }

        let event = await mailbox.next()
        #expect(event == .updates([update]))
    }

    /// Same regression, but for `markClosed()` instead of `record(_:)` — the stream ending in the
    /// same registration gap must not orphan the waiter either.
    @Test
    func markClosedBeforeRegisterStillResumesTheWaiterOnceRegistered() async throws {
        let mailbox = UpdateMailbox()

        mailbox.markClosed()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            mailbox.registerWaiter(token: 3, continuation: continuation)
        }

        let event = await mailbox.next()
        #expect(event == .closed)
    }

    @Test
    func nextReturnsQueuedUpdatesImmediatelyWithoutRegisteringAWaiter() async {
        let mailbox = UpdateMailbox()
        let update = DiagnosticUpdate(uri: DocumentURI("file:///c.swift"), diagnostics: [])
        mailbox.record(update)

        let event = await mailbox.next()

        #expect(event == .updates([update]))
    }

    @Test
    func nextReturnsClosedWhenNothingQueuedAndMailboxIsClosed() async {
        let mailbox = UpdateMailbox()
        mailbox.markClosed()

        let event = await mailbox.next()

        #expect(event == .closed)
    }
}
