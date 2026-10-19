import Darwin
import Dispatch
import Synchronization

@testable import FoundationModelsCodeContext

/// One call that `ProcessGroupChild` made to `RecordingProcessGroupCalls`.
enum ProcessGroupCall: Equatable, Sendable {
    /// A signal to the process group of the leader.
    case signal(Int32)

    /// The reap of the leader.
    case reap
}

/// A fake `ProcessGroupCalls` with no real process. It records each signal and the reap in
/// their order, and the test decides when the fake leader exits.
///
/// `waitForExit(of:)` blocks the reaper thread of `ProcessGroupChild` until the leader exits:
/// at `exit(status:)`, or at a signal to the group that ends the leader. A test must make the
/// leader exit on each path, or the reaper thread stays blocked.
final class RecordingProcessGroupCalls: ProcessGroupCalls {
    /// The signal that ends the fake leader, or `nil` when only `exit(status:)` ends it.
    private let endingSignal: Int32?

    /// Each call in its order.
    private let recordedCalls = Mutex<[ProcessGroupCall]>([])

    /// The termination status of the leader, set at its exit.
    private let exitStatus = Mutex<Int32>(.zero)

    /// Signalled one time at the exit of the leader.
    private let exitSignal = DispatchSemaphore(value: .zero)

    /// Whether the leader was reaped, and the waits for the reap.
    let reaped = CancellableWaiters.flag(isSet: false)

    /// Makes a fake whose leader runs until the test ends it.
    /// - Parameter endingSignal: The signal to the group that ends the leader, with that signal
    ///   as its termination status. With `nil`, only `exit(status:)` ends the leader.
    init(endingSignal: Int32? = nil) {
        self.endingSignal = endingSignal
    }

    /// Each call that the fake got, in its order.
    var calls: [ProcessGroupCall] {
        recordedCalls.withLock { calls in calls }
    }

    /// Ends the fake leader with `status`. Call it one time.
    /// - Parameter status: The termination status of the leader.
    func exit(status: Int32) {
        exitStatus.withLock { exitStatus in exitStatus = status }
        exitSignal.signal()
    }

    func waitForExit(of pid: pid_t) -> Int32 {
        exitSignal.wait()
        return exitStatus.withLock { exitStatus in exitStatus }
    }

    func reap(_ pid: pid_t) {
        recordedCalls.withLock { calls in calls.append(.reap) }
        reaped.update { isReaped in isReaped = true }
    }

    func send(_ signal: Int32, toGroup groupID: pid_t) {
        recordedCalls.withLock { calls in calls.append(.signal(signal)) }
        if signal == endingSignal {
            exit(status: signal)
        }
    }
}
