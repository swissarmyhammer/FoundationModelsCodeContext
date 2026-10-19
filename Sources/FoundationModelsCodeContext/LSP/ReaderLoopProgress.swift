import Synchronization

/// What the stdout reader loop of one `ProcessLanguageServerConnection` did so far: whether it
/// runs, and how many bytes and frames it read from the server.
///
/// The reader loop runs on a dedicated thread and records each read here. A request that times
/// out writes the snapshot to its log record, thus the record tells whether the response was lost
/// before the loop read it or after. The values are counts only, never a byte of the payload.
final class ReaderLoopProgress: Sendable {
    /// The phase of the reader loop.
    enum Phase: String, Sendable {
        /// The thread of the loop did not start to read yet.
        case notStarted = "not-started"

        /// The loop reads the stdout pipe of the server.
        case reading

        /// The loop stopped: at the end of the file, at a read error or at a bad frame header.
        case stopped
    }

    /// The state of the reader loop at one time.
    struct Snapshot: Equatable, Sendable {
        /// The phase of the loop.
        var phase: Phase

        /// The count of bytes that the loop read from the stdout pipe of the server.
        var byteCount: Int

        /// The count of complete JSON-RPC frames that the loop decoded from those bytes.
        var frameCount: Int
    }

    /// The state, guarded by its lock: the loop writes it and a timed-out request reads it.
    private let state = Mutex(Snapshot(phase: .notStarted, byteCount: .zero, frameCount: .zero))

    /// The current state of the loop.
    var snapshot: Snapshot {
        state.withLock { $0 }
    }

    /// Records that the loop started to read.
    func recordStart() {
        state.withLock { $0.phase = .reading }
    }

    /// Records one chunk of bytes that the loop read.
    /// - Parameter byteCount: The size of the chunk, in bytes.
    func recordRead(byteCount: Int) {
        state.withLock { $0.byteCount += byteCount }
    }

    /// Records the frames that the loop decoded from one chunk.
    /// - Parameter frameCount: The count of decoded frames.
    func recordFrames(_ frameCount: Int) {
        state.withLock { $0.frameCount += frameCount }
    }

    /// Records that the loop stopped and reads no more.
    func recordStop() {
        state.withLock { $0.phase = .stopped }
    }
}
