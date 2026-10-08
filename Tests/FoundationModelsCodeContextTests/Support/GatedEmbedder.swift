import Foundation
import FoundationModelsExtras

@testable import FoundationModelsCodeContext

/// The record of each `embed(texts:)` call of a `GatedEmbedder`, and the gate that
/// can hold those calls.
///
/// A test closes the gate to hold the embedding step at a known point. The
/// test then examines the system while the step is not complete. The step
/// continues when the test opens the gate, or when the task of the step is
/// cancelled.
///
/// The log keeps the probe calls of `MeasuredEmbedder` apart from the chunk
/// batches. A probe call is not in `batchSizes`, it does not stop at the gate,
/// and it does not end `waitForFirstCall()`.
actor EmbedCallLog {
    /// The number of texts in each chunk-batch `embed(texts:)` call, in call order.
    private(set) var batchSizes: [Int] = []

    /// The number of `embed(texts:)` calls that embedded the probe text of
    /// `MeasuredEmbedder`.
    private(set) var probeCallCount = 0

    /// `true` while each `embed(texts:)` call must stop at the gate.
    private var isGated = false

    /// The `embed(texts:)` calls that wait at the closed gate, by wait identifier.
    private var gateWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// The tests that wait for the first chunk-batch `embed(texts:)` call.
    private var firstCallWaiters: [CheckedContinuation<Void, Never>] = []

    /// Makes each subsequent `embed(texts:)` call stop until `openGate()`.
    func closeGate() {
        isGated = true
    }

    /// Releases each `embed(texts:)` call that waits at the gate, and stops the
    /// gate for subsequent calls.
    func openGate() {
        isGated = false
        let waiters = gateWaiters.values
        gateWaiters = [:]
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Returns when the embedder has received one chunk-batch `embed(texts:)` call
    /// or more.
    func waitForFirstCall() async {
        if !batchSizes.isEmpty {
            return
        }
        await withCheckedContinuation { continuation in
            firstCallWaiters.append(continuation)
        }
    }

    /// Records one chunk-batch `embed(texts:)` call, then waits while the gate is
    /// closed.
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

    /// Records one `embed(texts:)` call that embedded the probe text.
    func recordProbeCall() {
        probeCallCount += 1
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

/// A `PooledEmbedding` test double that records each call in an `EmbedCallLog`
/// and stops at the gate of that log.
///
/// The vectors are the vectors of `FakeEmbedder`, thus they are deterministic.
/// A call whose task is cancelled throws `CancellationError`, as a real
/// embedding model can do. A call that embeds only the probe text of
/// `MeasuredEmbedder` is recorded as a probe call and does not stop at the
/// gate.
struct GatedEmbedder: PooledEmbedding {
    /// The length of every vector this embedder produces.
    let vectorLength: Int

    /// The record of the calls, and the gate that holds them.
    let log: EmbedCallLog

    func embed(texts: [String]) async throws -> [[Float]] {
        if texts == [MeasuredEmbedder.probeText] {
            await log.recordProbeCall()
        } else {
            await log.recordCall(batchSize: texts.count)
        }
        try Task.checkCancellation()
        return try await FakeEmbedder(vectorLength: vectorLength).embed(texts: texts)
    }
}
