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
/// The state and the waits are in a `CancellableWaiters`. A wait ends when an
/// update is queued, when the mailbox is closed, or when the task of the wait
/// is cancelled. `CancellableWaiters` resumes a cancelled wait synchronously
/// from the cancel handler, thus a `TaskGroup` child that loses the race ends
/// at once. It also reads the state when the wait registers, thus a
/// `record(_:)` or a `markClosed()` before the registration still ends the
/// wait.
final class UpdateMailbox: Sendable {
    /// The values that the waits of `next()` read.
    private struct State: Sendable {
        /// Updates recorded since the last `next()` call took them.
        var queued: [DiagnosticUpdate] = []

        /// Whether the feeding stream has ended.
        var isClosed = false
    }

    /// The state, and the waits of `next()` for an update or for the close.
    private let waiters = CancellableWaiters(State()) { state in
        !state.queued.isEmpty || state.isClosed
    }

    /// Records one update, waking every suspended `next()` caller.
    /// - Parameter update: The update to record.
    func record(_ update: DiagnosticUpdate) {
        waiters.update { state in state.queued.append(update) }
    }

    /// Marks the mailbox closed (its feeding stream ended), waking every
    /// suspended `next()` caller.
    func markClosed() {
        waiters.update { state in state.isClosed = true }
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
        await waiters.wait()
        return waiters.update { state in
            if state.queued.isEmpty && state.isClosed {
                return .closed
            }
            defer { state.queued.removeAll() }
            return .updates(state.queued)
        }
    }
}
