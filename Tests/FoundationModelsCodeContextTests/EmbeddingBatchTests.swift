import Foundation
import GRDB
import Testing

@testable import FoundationModelsCodeContext

/// Tests for the batch bound and the cancellation of the embedding step of
/// `TreeSitterWorker`.
struct EmbeddingBatchTests {
    /// The dimension of the fake embedding vectors.
    private static let dimension = 8

    /// The number of functions in the fixture file. Each function is one chunk
    /// or more, thus the file needs more than one batch.
    private static let functionCount = 5

    /// The batch bound that the tests give to the worker.
    private static let batchSize = 2

    /// Writes one Swift file with `functionCount` functions into `root`.
    private static func writeFixture(in root: URL) throws {
        let source = (0..<functionCount)
            .map { index in "func function\(index)() -> Int {\n    return \(index)\n}\n" }
            .joined(separator: "\n")
        try write(source, to: "Many.swift", in: root)
    }

    /// Reads the number of chunks of the fixture file, and the number of those
    /// chunks that have an embedding.
    private static func chunkCounts(in store: Store) async throws -> (total: Int, embedded: Int) {
        try await store.read { db in
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ts_chunks") ?? 0
            let embedded = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ts_chunks WHERE embedding IS NOT NULL") ?? 0
            return (total, embedded)
        }
    }

    @Test
    func theEmbeddingStepSendsBatchesOfABoundedSize() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try Self.writeFixture(in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)
            let log = EmbedCallLog()

            try await TreeSitterWorker.run(
                store: store,
                rootDirectory: root,
                embedder: GatedEmbedder(dimension: Self.dimension, log: log),
                embeddingBatchSize: Self.batchSize
            )

            let counts = try await Self.chunkCounts(in: store)
            let batchSizes = await log.batchSizes
            #expect(counts.total > Self.batchSize)
            #expect(batchSizes.allSatisfy { $0 <= Self.batchSize })
            #expect(batchSizes.reduce(0, +) == counts.total)
            #expect(counts.embedded == counts.total)
        }
    }

    @Test
    func aCancelledTaskStopsTheEmbeddingStepBetweenBatches() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try Self.writeFixture(in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)
            let log = EmbedCallLog()
            await log.closeGate()

            let pass = Task {
                try await TreeSitterWorker.run(
                    store: store,
                    rootDirectory: root,
                    embedder: GatedEmbedder(dimension: Self.dimension, log: log),
                    embeddingBatchSize: Self.batchSize
                )
            }
            await log.waitForFirstCall()
            pass.cancel()

            await #expect(throws: CancellationError.self) {
                try await pass.value
            }
            let counts = try await Self.chunkCounts(in: store)
            #expect(await log.batchSizes.count == 1)
            #expect(counts.embedded == 0)
        }
    }
}
