import Foundation

/// A manually-advanced `Clock` for deterministic timeout tests.
///
/// `ProcessLanguageServerConnection` accepts an injectable `Clock` so its
/// 30-second per-request timeout can be exercised without a test actually
/// waiting 30 real seconds: construct the connection with a `ManualClock`,
/// issue a request that the scripted subprocess never answers, then call
/// `advance(by:)` to release the connection's internal `sleep(for:)` call
/// exactly as if that much wall-clock time had passed.
final class ManualClock: Clock, @unchecked Sendable {
    /// A point in `ManualClock` time, measured as an offset from the clock's start.
    struct Instant: InstantProtocol {
        /// The elapsed time since the clock was created.
        var offset: Duration

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        static func + (lhs: Instant, rhs: Duration) -> Instant {
            Instant(offset: lhs.offset + rhs)
        }

        static func - (lhs: Instant, rhs: Duration) -> Instant {
            Instant(offset: lhs.offset - rhs)
        }

        static func - (lhs: Instant, rhs: Instant) -> Duration {
            lhs.offset - rhs.offset
        }
    }

    private struct Waiter {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var currentInstant = Instant(offset: .zero)
    private var waiters: [Int: Waiter] = [:]
    private var cancelledTokensAwaitingRegistration: Set<Int> = []
    private var nextWaiterToken = 0

    /// The clock's current, manually-controlled instant.
    var now: Instant {
        lock.lock()
        defer { lock.unlock() }
        return currentInstant
    }

    /// The smallest duration this clock can represent; effectively unlimited precision.
    var minimumResolution: Duration { .nanoseconds(1) }

    /// Suspends until `deadline` is reached by a matching `advance(by:)` call, or until the
    /// calling task is cancelled.
    ///
    /// Registration and cancellation are both routed through a per-call token rather than
    /// resuming the continuation directly from `onCancel`: `withTaskCancellationHandler`'s
    /// `onCancel` closure can run *before* the operation closure that creates the continuation
    /// (if the task is already cancelled when `sleep` is called), so cancellation must be able to
    /// mark itself pending before a waiter even exists, and registration must check for that mark.
    /// - Parameters:
    ///   - deadline: The instant to suspend until.
    ///   - tolerance: Ignored; `ManualClock` has no scheduling slack.
    /// - Throws: `CancellationError` if the calling task is cancelled before `deadline` is reached.
    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let token = allocateWaiterToken()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                registerWaiter(token: token, deadline: deadline, continuation: continuation)
            }
        } onCancel: {
            cancelWaiter(token: token)
        }
    }

    /// Allocates a unique token identifying one in-flight `sleep(until:tolerance:)` call.
    private func allocateWaiterToken() -> Int {
        lock.lock()
        defer { lock.unlock() }
        defer { nextWaiterToken += 1 }
        return nextWaiterToken
    }

    /// Registers `continuation` as waiting for `deadline`, unless `token` was already cancelled
    /// before registration ran, or `deadline` has already passed.
    private func registerWaiter(token: Int, deadline: Instant, continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if cancelledTokensAwaitingRegistration.remove(token) != nil {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        if deadline <= currentInstant {
            lock.unlock()
            continuation.resume()
            return
        }
        waiters[token] = Waiter(deadline: deadline, continuation: continuation)
        lock.unlock()
    }

    /// Resumes `token`'s waiter with `CancellationError`, or marks it as cancelled ahead of
    /// registration if `registerWaiter(token:deadline:continuation:)` hasn't run yet.
    private func cancelWaiter(token: Int) {
        lock.lock()
        guard let waiter = waiters.removeValue(forKey: token) else {
            cancelledTokensAwaitingRegistration.insert(token)
            lock.unlock()
            return
        }
        lock.unlock()
        waiter.continuation.resume(throwing: CancellationError())
    }

    /// Polls until at least `count` callers are suspended in `sleep(until:tolerance:)`.
    ///
    /// Lets a test synchronize with code that races a `Clock.sleep(for:)` call against other
    /// work (e.g. `ProcessLanguageServerConnection`'s request timeout) before calling
    /// `advance(by:)`, instead of racing a real-time sleep against that code's own scheduling.
    /// The polling interval is real wall-clock time, but only as a synchronization primitive —
    /// the timeout duration under test is still driven entirely by `advance(by:)`.
    ///
    /// `count` matters whenever more than one concurrent sleeper is expected to register before
    /// the next `advance(by:)` (e.g. two daemons' health loops each sleeping on the same clock):
    /// waiting for only the first arrival and then advancing would let the clock move past a
    /// still-unregistered sleeper's intended deadline, since that sleeper's later `sleep(for:)`
    /// call computes its deadline from the clock's already-advanced `now`.
    /// - Parameter count: How many distinct waiters must be registered before returning. Defaults
    ///   to 1.
    func waitForWaiter(count: Int = 1) async {
        while !hasAtLeastWaitersSynchronously(count) {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    /// Synchronously checks `waiters`' count under `lock`.
    ///
    /// `NSLock.lock()`/`unlock()` are unavailable directly inside an `async` function body (to
    /// discourage holding a lock across a suspension point), so this plain synchronous helper is
    /// the call site `waitForWaiter(count:)` delegates to instead.
    private func hasAtLeastWaitersSynchronously(_ count: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count >= count
    }

    /// Advances the clock by `duration`, releasing every waiter whose deadline has now passed.
    /// - Parameter duration: How far forward to move the clock.
    func advance(by duration: Duration) {
        lock.lock()
        currentInstant = currentInstant.advanced(by: duration)
        let readyTokens = waiters.filter { $0.value.deadline <= currentInstant }.map(\.key)
        let readyWaiters = readyTokens.compactMap { waiters.removeValue(forKey: $0) }
        lock.unlock()

        for waiter in readyWaiters {
            waiter.continuation.resume()
        }
    }
}
