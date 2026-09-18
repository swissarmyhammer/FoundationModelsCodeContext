import Foundation
import FoundationModelsCodeContext

/// The record of each `embed(_:)` call of a `GatedEmbedder`, and the gate that
/// can hold those calls.
///
/// A test closes the gate to hold the embedding step at a known point. The
/// test then examines the system while the step is not complete. The step
/// continues when the test opens the gate, or when the task of the step is
/// cancelled.
actor EmbedCallLog {
    /// The number of texts in each `embed(_:)` call, in call order.
    private(set) var batchSizes: [Int] = []

    /// `true` while each `embed(_:)` call must stop at the gate.
    private var isGated = false

    /// The `embed(_:)` calls that wait at the closed gate, by wait identifier.
    private var gateWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// The tests that wait for the first `embed(_:)` call.
    private var firstCallWaiters: [CheckedContinuation<Void, Never>] = []

    /// Makes each subsequent `embed(_:)` call stop until `openGate()`.
    func closeGate() {
        isGated = true
    }

    /// Releases each `embed(_:)` call that waits at the gate, and stops the
    /// gate for subsequent calls.
    func openGate() {
        isGated = false
        let waiters = gateWaiters.values
        gateWaiters = [:]
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Returns when the embedder has received one `embed(_:)` call or more.
    func waitForFirstCall() async {
        if !batchSizes.isEmpty {
            return
        }
        await withCheckedContinuation { continuation in
            firstCallWaiters.append(continuation)
        }
    }

    /// Records one `embed(_:)` call, then waits while the gate is closed.
    ///
    /// The wait stops when the gate opens, and also when the task of the
    /// caller is cancelled.
    ///
    /// - Parameter batchSize: The number of texts in the call.
    func recordCall(batchSize: Int) async {
        batchSizes.append(batchSize)
        let waiters = firstCallWaiters
        firstCallWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
        if isGated {
            await waitAtGate()
        }
    }

    /// Waits until the gate opens or the task of the caller is cancelled.
    private func waitAtGate() async {
        let waitIdentifier = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    gateWaiters[waitIdentifier] = continuation
                }
            }
        } onCancel: {
            // The cancellation handler is synchronous, thus it needs a task
            // to get into the actor.
            Task { await self.releaseGateWaiter(waitIdentifier) }
        }
    }

    /// Releases the one call that waits with `waitIdentifier`, if it waits.
    ///
    /// - Parameter waitIdentifier: The identifier of the wait to release.
    private func releaseGateWaiter(_ waitIdentifier: UUID) {
        gateWaiters.removeValue(forKey: waitIdentifier)?.resume()
    }
}

/// A `TextEmbedding` test double that records each call in an `EmbedCallLog`
/// and stops at the gate of that log.
///
/// The vectors are the vectors of `FakeEmbedder`, thus they are deterministic.
/// A call whose task is cancelled throws `CancellationError`, as a real
/// embedding model can do.
struct GatedEmbedder: TextEmbedding {
    let dimension: Int

    /// The record of the calls, and the gate that holds them.
    let log: EmbedCallLog

    func embed(_ texts: [String]) async throws -> [[Float]] {
        await log.recordCall(batchSize: texts.count)
        try Task.checkCancellation()
        return try await FakeEmbedder(dimension: dimension).embed(texts)
    }
}
