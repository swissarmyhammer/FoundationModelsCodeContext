import Synchronization

/// A state behind a lock, and the waits for a condition on that state. Each wait returns when the
/// condition is true, or when the task of the wait is cancelled.
///
/// The waits are cancellable. A plain `await` on an unstructured `Task` does not return at a
/// cancel, thus a race against a time limit (see `Clock.waitForCompletion(atMost:_:)`) needs this
/// type.
///
/// This is a `Mutex`-guarded class, not an actor: `update(_:)` can run on a thread that is not in
/// the cooperative pool (for example the reaper thread of `ProcessGroupChild`), and the cancel
/// handler of `wait()` runs synchronously. Neither of them can `await`.
///
/// Each wait has a token, and the token has one of three entries:
/// - `pending`: the wait did not register its continuation yet.
/// - `suspended`: the continuation of the wait is registered.
/// - `cancelled`: the cancel handler ran before the registration.
///
/// The cancel handler can run before the wait registers its continuation (for example when the
/// task was cancelled before the wait started). Then it records `cancelled`, and the registration
/// resumes the continuation at once. A token leaves the table when its continuation resumes, thus
/// a cancel after the resume finds no entry and does nothing.
final class CancellableWaiters<State: Sendable>: Sendable {
    /// The progress of one wait.
    private enum Entry {
        /// The wait did not register its continuation yet.
        case pending

        /// The continuation of the wait is registered, and the condition was false at the
        /// registration.
        case suspended(CheckedContinuation<Void, Never>)

        /// The cancel handler ran before the registration.
        case cancelled
    }

    /// The values behind the lock.
    private struct Storage {
        /// The state that the condition reads.
        var state: State

        /// The token of the most recent wait.
        var lastToken = 0

        /// The entry of each wait that did not return yet, by token.
        var entries: [Int: Entry] = [:]
    }

    /// The lock and its values.
    private let storage: Mutex<Storage>

    /// The condition that ends a wait. It runs while the lock is held, thus it must be fast and
    /// must not call this object.
    private let isSatisfied: @Sendable (State) -> Bool

    /// Keeps `initialState` and the condition of the waits.
    /// - Parameters:
    ///   - initialState: The state before the first `update(_:)`.
    ///   - isSatisfied: The condition that ends a wait.
    init(_ initialState: State, isSatisfied: @escaping @Sendable (State) -> Bool) {
        storage = Mutex(Storage(state: initialState))
        self.isSatisfied = isSatisfied
    }

    /// Reads the state while the lock is held.
    /// - Parameter body: The read. It must not call this object.
    /// - Returns: The value of `body`.
    func read<Value: Sendable>(_ body: (State) -> Value) -> Value {
        storage.withLock { storage in body(storage.state) }
    }

    /// Changes the state while the lock is held. When the condition is then true, resumes each
    /// suspended wait.
    ///
    /// The change can also give a value, thus a read and a change occur in one lock step (for
    /// example, a change that takes the queued items and empties the queue).
    /// - Parameter change: The change. It must not call this object.
    /// - Returns: The value of `change`.
    func update<Value>(_ change: (inout State) -> Value) -> Value {
        let (value, resumed) = storage.withLock { storage in
            let value = change(&storage.state)
            let resumed = isSatisfied(storage.state) ? Self.removeSuspended(from: &storage.entries) : []
            return (value, resumed)
        }
        for continuation in resumed {
            continuation.resume()
        }
        return value
    }

    /// Suspends until the condition is true, or until the task is cancelled. Returns at once when
    /// the condition is already true, or when the task is already cancelled.
    func wait() async {
        let token = storage.withLock { storage in
            storage.lastToken += 1
            storage.entries[storage.lastToken] = .pending
            return storage.lastToken
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                register(continuation, token: token)
            }
        } onCancel: {
            cancelWait(token: token)
        }
    }

    /// Removes each `suspended` entry from `entries`. A `pending` entry stays: its registration
    /// reads the condition again.
    /// - Parameter entries: The entries of the waits.
    /// - Returns: The continuations of the removed entries.
    private static func removeSuspended(from entries: inout [Int: Entry]) -> [CheckedContinuation<Void, Never>] {
        let suspended = entries.compactMap { token, entry -> (Int, CheckedContinuation<Void, Never>)? in
            guard case .suspended(let continuation) = entry else { return nil }
            return (token, continuation)
        }
        for (token, _) in suspended {
            entries[token] = nil
        }
        return suspended.map { _, continuation in continuation }
    }

    /// Keeps `continuation` until an update makes the condition true, or resumes it at once when
    /// the condition is true or the wait was cancelled.
    /// - Parameters:
    ///   - continuation: The continuation of the wait.
    ///   - token: The token of the wait.
    private func register(_ continuation: CheckedContinuation<Void, Never>, token: Int) {
        let resumesNow = storage.withLock { storage in
            var isCancelled = false
            if case .cancelled? = storage.entries[token] {
                isCancelled = true
            }
            guard isCancelled || isSatisfied(storage.state) else {
                storage.entries[token] = .suspended(continuation)
                return false
            }
            storage.entries[token] = nil
            return true
        }
        if resumesNow {
            continuation.resume()
        }
    }

    /// Resumes the wait `token` after a cancel, or records the cancel when the wait did not
    /// register yet. Does nothing when the wait already returned.
    /// - Parameter token: The token of the wait.
    private func cancelWait(token: Int) {
        let continuation: CheckedContinuation<Void, Never>? = storage.withLock { storage in
            switch storage.entries[token] {
            case .pending?:
                storage.entries[token] = .cancelled
                return nil
            case .suspended(let continuation)?:
                storage.entries[token] = nil
                return continuation
            case .cancelled?, nil:
                return nil
            }
        }
        continuation?.resume()
    }
}
