import Dispatch
import Foundation

@testable import FoundationModelsCodeContext

/// A gate that blocks the thread that calls `hold()` until a test calls
/// `open()`.
///
/// A test uses the gate to keep an executor busy, for example the executor of an
/// actor or of the main actor. A job on that executor calls `hold()`, thus no
/// other job of the executor can run until the test opens the gate. The test then
/// shows that an operation answers without that executor.
///
/// The gate blocks a real thread, thus a test must open each gate that it holds,
/// on each path.
struct ThreadGate: Sendable {
    /// Signalled one time when `hold()` starts to block.
    private let heldSignal = DispatchSemaphore(value: 0)

    /// Signalled one time when the test opens the gate.
    private let openSignal = DispatchSemaphore(value: 0)

    /// Blocks the thread of the caller until `open()`.
    ///
    /// Call it from a synchronous job of the executor that the test holds.
    func hold() {
        heldSignal.signal()
        openSignal.wait()
    }

    /// Returns when a thread blocks in `hold()`.
    ///
    /// The wait for the semaphore runs on a GCD thread, not on a thread of the
    /// Swift cooperative pool.
    func waitUntilHeld() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                heldSignal.wait()
                continuation.resume()
            }
        }
    }

    /// Blocks the main actor until `open()`.
    ///
    /// While this method blocks, no other job of the main actor can run.
    @MainActor
    func holdMainActor() {
        hold()
    }

    /// Releases the thread that blocks in `hold()`.
    func open() {
        openSignal.signal()
    }
}

extension CodeContext {
    /// Blocks the executor of this actor until `gate` opens.
    ///
    /// The method is synchronous and isolated to the actor, thus while it blocks,
    /// no other job of the actor can run.
    ///
    /// - Parameter gate: The gate that the test opens.
    func blockExecutor(until gate: ThreadGate) {
        gate.hold()
    }
}
