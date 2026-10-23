import Synchronization

/// Tells a test, with no wait, whether a task has ended.
///
/// A test that must show that a task ends promptly cannot await `Task.value`: a task that does
/// not end would hold the test until its time limit. The task marks this flag at its end (in a
/// `defer`), and the test polls `hasEnded` with a real-time limit through
/// `waitUntil(timeout:pollInterval:_:)`.
final class TaskEndFlag: Sendable {
    private let ended = Mutex(false)

    /// Whether the task called `markEnded()`.
    var hasEnded: Bool {
        ended.withLock { $0 }
    }

    /// Records that the task ended.
    func markEnded() {
        ended.withLock { $0 = true }
    }
}
