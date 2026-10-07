import Foundation
import FoundationModelsCodeContext

/// The thread facts that a `RecordingFileEventSource` records at one
/// `start(rootDirectory:handler:)` call.
struct FileEventSourceStartRecord: Sendable, Equatable {
    /// `true` when the call ran on the main thread.
    let isMainThread: Bool

    /// The label of the dispatch queue that ran the call.
    let queueLabel: String
}

/// A `FileEventSource` test double that records the thread of each
/// `start(rootDirectory:handler:)` call and each `stop()` of its
/// subscriptions. It never delivers an event.
///
/// A gated source holds each `start` call until `openGate()`. Thus a test can
/// do work while a start is not complete. The gate blocks the thread that
/// calls `start`, thus only a caller that is not on the cooperative pool can
/// use a gated source safely.
///
/// The synchronization invariant: `lock` guards `records` and `stopCount`. The
/// other stored properties are `let` values of `Sendable` types.
// swiftlint:disable:next no_unchecked_sendable
final class RecordingFileEventSource: FileEventSource, @unchecked Sendable {
    /// Guards `records` and `stopCount`.
    private let lock = NSLock()

    /// One record for each `start` call, in call order.
    private var records: [FileEventSourceStartRecord] = []

    /// The number of `stop()` calls on the subscriptions of this source.
    private var stopCount = 0

    /// Holds each `start` call while the gate is closed. `nil` for a source
    /// with no gate.
    private let gate: DispatchSemaphore?

    /// Gets one element when a `start` call begins.
    private let startCallContinuation: AsyncStream<Void>.Continuation

    /// One element for each `start` call that began, in call order.
    let startCalls: AsyncStream<Void>

    /// Creates a recording source.
    ///
    /// - Parameter isGated: `true` to hold each `start` call until
    ///   `openGate()`. Defaults to `false`.
    init(isGated: Bool = false) {
        gate = isGated ? DispatchSemaphore(value: 0) : nil
        (startCalls, startCallContinuation) = AsyncStream<Void>.makeStream()
    }

    /// The record of each `start` call up to now, in call order.
    var startRecords: [FileEventSourceStartRecord] {
        lock.withLock { records }
    }

    /// The number of `stop()` calls on the subscriptions of this source up to
    /// now.
    var stoppedSubscriptionCount: Int {
        lock.withLock { stopCount }
    }

    /// Releases one `start` call that waits at the gate.
    func openGate() {
        gate?.signal()
    }

    /// Records the thread of the call, tells `startCalls`, then waits at the
    /// gate of a gated source.
    ///
    /// - Parameters:
    ///   - rootDirectory: Not used. The source watches nothing.
    ///   - handler: Not used. The source delivers no event.
    /// - Returns: A subscription whose `stop()` this source counts.
    func start(
        rootDirectory: URL,
        handler: @escaping @Sendable (RawFileEvent) async -> Void
    ) -> any FileEventSubscription {
        let record = FileEventSourceStartRecord(
            isMainThread: Thread.isMainThread,
            queueLabel: String(cString: __dispatch_queue_get_label(nil))
        )
        lock.withLock { records.append(record) }
        startCallContinuation.yield()
        gate?.wait()
        return RecordingFileEventSubscription(source: self)
    }

    /// Counts one `stop()` call on a subscription of this source.
    fileprivate func recordStop() {
        lock.withLock { stopCount += 1 }
    }
}

/// The subscription of a `RecordingFileEventSource`. `stop()` tells the source.
private struct RecordingFileEventSubscription: FileEventSubscription {
    /// The source that counts each `stop()` call.
    let source: RecordingFileEventSource

    func stop() {
        source.recordStop()
    }
}
