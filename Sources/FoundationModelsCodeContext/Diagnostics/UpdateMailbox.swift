import Foundation

/// One `UpdateMailbox.next()` call's outcome: either updates arrived since
/// the last call, or the mailbox was marked closed with nothing queued.
enum MailboxEvent: Sendable, Equatable {
    /// One or more updates recorded since the last `next()` call.
    case updates([DiagnosticUpdate])

    /// The mailbox was closed (its feeding stream ended) with nothing queued.
    case closed
}

/// A cancellation-safe single-slot event notifier bridging a background
/// stream-drain task to `Settle`'s per-iteration race.
///
/// `Settle.settleStream` needs to wait for "the next diagnostics update" as
/// one participant in a `TaskGroup` race against timer sleeps, cancelling
/// whichever participant loses. Racing `AsyncStream.Iterator.next()`
/// directly would require depending on it reliably unblocking the instant
/// its enclosing task is cancelled — see `Settle`'s type-level doc comment
/// for why this port doesn't want to lean on that. `UpdateMailbox` sidesteps
/// the question entirely: a persistent background task drains the stream by
/// calling `record(_:)`, and the settle loop calls `next()`.
///
/// A plain `NSLock`-guarded class rather than an `actor`: a `TaskGroup`
/// child suspended in `next()` must have its continuation resumed
/// *synchronously*, from directly inside `withTaskCancellationHandler`'s
/// `onCancel` closure (which is not `async`) — that closure firing is the
/// *only* signal a losing race gets. An actor's isolated methods can only be
/// reached with `await`, which would force `onCancel` to spawn a detached
/// `Task` to call back into it; that child task then finishes only once
/// *that separately scheduled task* gets around to running, and
/// `withTaskGroup` cannot return until every child finishes — a gap that,
/// once observed, wedged an entire test binary forever (nothing left to run,
/// nothing left to resume the suspended continuation). Matches
/// `ManualClock.sleep(until:tolerance:)`'s identical synchronous
/// cancellation handling (`Tests/FoundationModelsCodeContextTests/Support/ManualClock.swift`)
/// and this package's own `PendingRequestTable`
/// (`Sources/FoundationModelsCodeContext/LSP/ProcessLanguageServerConnection.swift`),
/// both lock-guarded for the exact same reason.
///
/// Registration and cancellation are both routed through a per-call token,
/// exactly like `ManualClock`'s own waiter bookkeeping:
/// `withTaskCancellationHandler`'s `onCancel` closure can run *before* the
/// operation closure that creates the continuation (e.g. when the calling
/// task is already cancelled the instant `next()` is called, or when a
/// losing `TaskGroup` child is cancelled before its operation even starts),
/// so cancellation must be able to mark itself pending before a waiter even
/// exists, and registration must check for that mark — without this, a
/// `next()` call embedded in a `TaskGroup` that loses its race could
/// register its continuation *after* the cancellation already ran, and hang
/// forever waiting for a resume that will never come.
final class UpdateMailbox: @unchecked Sendable {
    private let lock = NSLock()

    /// Updates recorded since the last `next()` call drained them.
    private var queued: [DiagnosticUpdate] = []

    /// Whether the feeding stream has ended.
    private var isClosed = false

    /// In-flight `next()` callers' continuations, keyed by their waiter token.
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]

    /// Tokens cancelled before `registerWaiter(token:continuation:)` ran for them.
    private var cancelledTokensAwaitingRegistration: Set<Int> = []

    /// The token the next `next()` call will register under.
    private var nextWaiterToken = 0

    /// Records one update, waking every suspended `next()` caller.
    /// - Parameter update: The update to record.
    func record(_ update: DiagnosticUpdate) {
        mutateStateAndResumeWaiters { queued.append(update) }
    }

    /// Marks the mailbox closed (its feeding stream ended), waking every
    /// suspended `next()` caller.
    func markClosed() {
        mutateStateAndResumeWaiters { isClosed = true }
    }

    /// Applies `mutate` under the lock, then drains and resumes every
    /// suspended `next()` caller — the shared lock-mutate-extract-resume
    /// pattern behind both `record(_:)` and `markClosed()`, which differ only
    /// in what state they mutate before waking waiters.
    /// - Parameter mutate: The state change to apply while holding the lock (appending to `queued`, or setting `isClosed`).
    private func mutateStateAndResumeWaiters(_ mutate: () -> Void) {
        lock.lock()
        mutate()
        let toResume = waiters
        waiters.removeAll()
        lock.unlock()
        for continuation in toResume.values {
            continuation.resume()
        }
    }

    /// Waits for at least one update to be recorded (or the mailbox to
    /// close) since the last call, then drains and returns everything
    /// queued.
    ///
    /// Cancellation-safe: a cancelled caller is resumed immediately rather
    /// than left suspended forever. A cancelled call may return
    /// `.updates([])` (nothing new, and not yet closed) — harmless for
    /// `Settle`'s race, which only ever reads the *first* task to complete
    /// out of a `TaskGroup` and discards every other result regardless of
    /// what it was.
    /// - Returns: Whatever was recorded since the last call, or `.closed` if
    ///   nothing was queued and the mailbox has since closed.
    func next() async -> MailboxEvent {
        if let drained = takeQueuedIfAny() {
            return drained
        }
        let token = allocateWaiterToken()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                registerWaiter(token: token, continuation: continuation)
            }
        } onCancel: {
            cancelWaiter(token: token)
        }
        return takeQueuedIfAny() ?? .updates([])
    }

    /// Allocates a unique token identifying one in-flight `next()` call.
    private func allocateWaiterToken() -> Int {
        lock.lock()
        defer { lock.unlock() }
        defer { nextWaiterToken += 1 }
        return nextWaiterToken
    }

    /// Registers `continuation` as waiting under `token`, unless `token` was
    /// already cancelled before registration ran, or `record(_:)`/`markClosed()`
    /// already ran since the caller's own `takeQueuedIfAny()` check came up
    /// empty — in either case it resumes immediately instead of registering.
    ///
    /// That second check matters exactly like `ManualClock.registerWaiter(token:deadline:continuation:)`'s
    /// `deadline <= currentInstant` check (`Tests/FoundationModelsCodeContextTests/Support/ManualClock.swift`):
    /// `next()` calls `takeQueuedIfAny()` *before* creating this continuation, so there's a window
    /// — however small — between that miss and this registration actually running in which
    /// `record(_:)`/`markClosed()` can run on another task. Before this check existed, `record(_:)`
    /// running in that window found `waiters` still empty (nothing to resume), appended to
    /// `queued`, and returned; registration then ran anyway and stored the continuation regardless,
    /// orphaning it — nothing but the *entire* `Settle.race(...)` `TaskGroup`'s eventual
    /// cancellation (from a sibling `Clock.sleep(until:)` branch winning) would ever wake it, and if
    /// that branch was itself starved of a chance to run under the same scheduling pressure that
    /// lost this race, the continuation — and the whole quiescence loop awaiting it — hung forever.
    /// Not `private`: unit-tested directly (`UpdateMailboxTests`), since forcing the exact
    /// register-after-record ordering this guards against through the public `next()`/`record(_:)`
    /// API alone would mean winning a race on demand rather than sequencing it deterministically —
    /// `next()`'s own `takeQueuedIfAny()` fast path would otherwise consume a `record(_:)` call made
    /// before `next()` starts, never reaching this method at all.
    func registerWaiter(token: Int, continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if cancelledTokensAwaitingRegistration.remove(token) != nil {
            lock.unlock()
            continuation.resume()
            return
        }
        if !queued.isEmpty || isClosed {
            lock.unlock()
            continuation.resume()
            return
        }
        waiters[token] = continuation
        lock.unlock()
    }

    /// Resumes `token`'s waiter, or marks it as cancelled ahead of
    /// registration if `registerWaiter(token:continuation:)` hasn't run yet.
    ///
    /// Runs synchronously on whatever thread `withTaskCancellationHandler`'s
    /// `onCancel` closure fires on — see this type's doc comment for why
    /// that must not require an `await` to reach.
    private func cancelWaiter(token: Int) {
        lock.lock()
        guard let continuation = waiters.removeValue(forKey: token) else {
            cancelledTokensAwaitingRegistration.insert(token)
            lock.unlock()
            return
        }
        lock.unlock()
        continuation.resume()
    }

    /// Drains and returns `queued` as `.updates`, or `.closed` if empty and
    /// `isClosed`, or `nil` if there's nothing to report yet.
    private func takeQueuedIfAny() -> MailboxEvent? {
        lock.lock()
        defer { lock.unlock() }
        guard !queued.isEmpty else {
            return isClosed ? .closed : nil
        }
        defer { queued.removeAll() }
        return .updates(queued)
    }
}
