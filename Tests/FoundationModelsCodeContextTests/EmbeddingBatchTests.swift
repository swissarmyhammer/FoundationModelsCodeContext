import Foundation
import GRDB
import Testing

@testable import FoundationModelsCodeContext

/// Tests for the batch bound, the cancellation and the dimension check of the
/// embedding step of `TreeSitterWorker`.
///
/// `TextEmbedding` declares no vector length. The worker gets the dimension
/// from the length of the first vector that the embedder returns, and embeds
/// one probe text when the embedder has returned no vector yet.
struct EmbeddingBatchTests {
    /// The dimension of the fake embedding vectors.
    private static let dimension = 8

    /// The dimension of the vectors of an earlier embedder, which is not
    /// `dimension`.
    private static let earlierDimension = 16

    /// The number of functions in the fixture file. Each function is one chunk
    /// or more, thus the file needs more than one batch.
    private static let functionCount = 5

    /// The batch bound that the tests give to the worker.
    private static let batchSize = 2

    /// The error of an embedder that cannot embed.
    private struct EmbedderFailure: Error {}

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

    /// Reads the length of each stored chunk embedding.
    private static func storedVectorLengths(in store: Store) async throws -> Set<Int> {
        let embeddings: [Data] = try await store.read { db in
            try Data.fetchAll(db, sql: "SELECT embedding FROM ts_chunks WHERE embedding IS NOT NULL")
        }
        return Set(embeddings.map { EmbeddingCodec.decode($0).count })
    }

    /// Writes the fixture into `root`, and records it in `store` as dirty.
    private static func prepareFixture(in root: URL, store: Store) async throws {
        try writeFixture(in: root)
        _ = try await Reconciler.reconcile(store: store, rootDirectory: root)
    }

    @Test
    func theEmbeddingStepSendsBatchesOfABoundedSize() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.prepareFixture(in: root, store: store)
            let log = EmbedCallLog()

            try await TreeSitterWorker.run(
                store: store,
                rootDirectory: root,
                embedder: GatedEmbedder(vectorLength: Self.dimension, log: log),
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
            try await Self.prepareFixture(in: root, store: store)
            let log = EmbedCallLog()
            await log.closeGate()

            let pass = Task {
                try await TreeSitterWorker.run(
                    store: store,
                    rootDirectory: root,
                    embedder: GatedEmbedder(vectorLength: Self.dimension, log: log),
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

    // MARK: - Dimension from the first vector

    @Test
    func theStoredDimensionIsTheLengthOfTheFirstVectorThatTheEmbedderReturns() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.prepareFixture(in: root, store: store)
            let log = EmbedCallLog()

            try await TreeSitterWorker.run(
                store: store,
                rootDirectory: root,
                embedder: GatedEmbedder(vectorLength: Self.dimension, log: log)
            )

            #expect(try await store.embedderDimension() == Self.dimension)
            #expect(try await Self.storedVectorLengths(in: store) == [Self.dimension])
        }
    }

    @Test
    func aPassWithNoDirtyFileEmbedsTheProbeOneTimeToLearnTheDimension() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            let log = EmbedCallLog()

            try await TreeSitterWorker.run(
                store: store,
                rootDirectory: root,
                embedder: GatedEmbedder(vectorLength: Self.dimension, log: log)
            )

            #expect(await log.probeCallCount == 1)
            #expect(await log.batchSizes.isEmpty)
            #expect(try await store.embedderDimension() == Self.dimension)
        }
    }

    @Test
    func aStoredDimensionThatIsNotTheVectorLengthMakesThePassEmbedEachChunkAgain() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.prepareFixture(in: root, store: store)
            try await TreeSitterWorker.run(
                store: store,
                rootDirectory: root,
                embedder: FakeEmbedder(vectorLength: Self.earlierDimension)
            )
            #expect(try await store.embedderDimension() == Self.earlierDimension)
            let log = EmbedCallLog()

            // No file is dirty in this pass. Only the embedder changed.
            try await TreeSitterWorker.run(
                store: store,
                rootDirectory: root,
                embedder: GatedEmbedder(vectorLength: Self.dimension, log: log)
            )

            let counts = try await Self.chunkCounts(in: store)
            #expect(await log.probeCallCount == 1)
            #expect(await log.batchSizes.reduce(0, +) == counts.total)
            #expect(counts.embedded == counts.total)
            #expect(try await Self.storedVectorLengths(in: store) == [Self.dimension])
            #expect(try await store.embedderDimension() == Self.dimension)
        }
    }

    @Test
    func aFailedProbeSkipsTheEmbeddingStepAndRecordsNoDimension() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.prepareFixture(in: root, store: store)

            try await TreeSitterWorker.run(
                store: store,
                rootDirectory: root,
                embedder: FakeEmbedder(vectorLength: Self.dimension, failure: EmbedderFailure())
            )

            #expect(try await store.embedderDimension() == nil)
            #expect(try await Self.chunkCounts(in: store).embedded == 0)
        }
    }

    @Test
    func aProbeVectorWithNoComponentSkipsTheEmbeddingStepAndRecordsNoDimension() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.prepareFixture(in: root, store: store)

            try await TreeSitterWorker.run(
                store: store,
                rootDirectory: root,
                embedder: FakeEmbedder(vectorLength: 0)
            )

            #expect(try await store.embedderDimension() == nil)
            #expect(try await Self.chunkCounts(in: store).embedded == 0)
        }
    }
}
