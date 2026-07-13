import Foundation
import GRDB
import RankKit
import Testing

@testable import CodeContextKit

/// L2-normalizes `vector`, or returns it unchanged if its magnitude is `0`.
private func normalized(_ vector: [Float]) -> [Float] {
    let magnitude = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
    guard magnitude > 0 else { return vector }
    return vector.map { $0 / magnitude }
}

/// Tests for `RankKit.CosineScoring.matvecScores(matrix:rowCount:dimension:queryVector:)`
/// (the primitive `SearchCorpusSnapshot.cosineScores(queryVector:)` wraps):
/// the `vDSP_mmul`-backed matvec against a scalar dot-product reference, plus
/// its documented degenerate-input behavior.
struct SearchCorpusMatvecTests {
    @Test
    func matvecCosineScoresMatchesScalarDotProductReferenceWithinTolerance() {
        let rowCount = 37
        let dimension = 13
        let matrixRows = (0..<rowCount).map { _ in normalized((0..<dimension).map { _ in Float.random(in: -1...1) }) }
        let matrix = matrixRows.flatMap { $0 }
        let queryVector = normalized((0..<dimension).map { _ in Float.random(in: -1...1) })

        let matvecScores = CosineScoring.matvecScores(
            matrix: matrix, rowCount: rowCount, dimension: dimension, queryVector: queryVector
        )

        #expect(matvecScores.count == rowCount)
        for rowIndex in 0..<rowCount {
            let scalarDotProduct = zip(matrixRows[rowIndex], queryVector).reduce(Float(0)) { $0 + $1.0 * $1.1 }
            #expect(abs(matvecScores[rowIndex] - scalarDotProduct) < 1e-5)
        }
    }

    @Test
    func matvecCosineScoresIsZeroWhenQueryDimensionDoesNotMatch() {
        let matrix: [Float] = [1, 0, 0, 0, 1, 0]
        let scores = CosineScoring.matvecScores(matrix: matrix, rowCount: 2, dimension: 3, queryVector: [1, 0])
        #expect(scores == [0.0, 0.0])
    }

    @Test
    func matvecCosineScoresIsEmptyForZeroRows() {
        let scores = CosineScoring.matvecScores(matrix: [], rowCount: 0, dimension: 3, queryVector: [1, 0, 0])
        #expect(scores.isEmpty)
    }
}

/// Tests for `SearchCorpus`: lazy loading and generation-based staleness
/// invalidation.
struct SearchCorpusTests {
    @Test
    func snapshotReloadsAfterANewWriteWithoutRecreatingTheCorpus() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await insertChunk(store: store, filePath: "A.swift", symbolPath: "A.first", text: "first chunk body")
            let corpus = SearchCorpus(store: store)

            let firstSnapshot = try await corpus.snapshot()
            #expect(firstSnapshot.chunkCount == 1)

            try await insertChunk(store: store, filePath: "B.swift", symbolPath: "B.second", text: "second chunk body")

            let secondSnapshot = try await corpus.snapshot()
            #expect(secondSnapshot.chunkCount == 2)
            #expect(secondSnapshot.symbolPaths.contains("B.second"))
        }
    }

    @Test
    func snapshotReusesCacheWhenStoreHasNotWrittenSinceLastLoad() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await insertChunk(store: store, filePath: "A.swift", symbolPath: "A.first", text: "first chunk body")
            let corpus = SearchCorpus(store: store)

            let firstSnapshot = try await corpus.snapshot()
            let secondSnapshot = try await corpus.snapshot()

            #expect(firstSnapshot.chunkIds == secondSnapshot.chunkIds)
        }
    }
}

/// End-to-end tests for `SearchCode.run(corpus:embedder:query:topK:weights:)`:
/// keyword-only and semantic-only golden hits, fused-ranking ordering,
/// generation staleness through the full op, and degraded (no-embedder)
/// mode — per the task's `/tdd` workflow and acceptance criteria.
struct SearchCodeTests {
    private static let embeddingDimension = 16

    // MARK: - Golden relevance: keyword-only, semantic-only, fused ordering

    @Test
    func keywordOnlyChunkIsFoundByBM25EvenWithoutAnEmbedding() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await insertChunk(
                store: store,
                filePath: "Network.swift",
                symbolPath: "Network.retryBackoffStrategy",
                text: "apply retry backoff strategy before requesting again",
                embedding: nil
            )
            let corpus = SearchCorpus(store: store)

            let result = try await SearchCode.run(corpus: corpus, embedder: FakeEmbedder(dimension: Self.embeddingDimension), query: "retry backoff strategy")

            let hit = try #require(result.hits.first { $0.symbolPath == "Network.retryBackoffStrategy" })
            #expect(hit.hit.signals.bm25 > 0.0)
            // Never embedded, so its cosine contribution is exactly 0.0 —
            // this chunk is found by BM25 alone, not semantic similarity.
            #expect(hit.hit.signals.cosine == 0.0)
        }
    }

    @Test
    func semanticOnlyChunkIsFoundByCosineDespiteNoLexicalOverlap() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            let query = "retry backoff strategy"
            let embedder = FakeEmbedder(dimension: Self.embeddingDimension)

            // A chunk with zero token/trigram overlap with `query` — verified
            // directly below, per the "assert the per-signal claim directly"
            // convention — but whose stored embedding is crafted to
            // be *exactly* the query's own embedding (FakeEmbedder is
            // deterministic, so embedding `query` again at search time
            // reproduces the same vector). This isolates the cosine signal:
            // the only way this chunk can be found is via semantic
            // similarity, since it can't be found via BM25 or trigram.
            // Digit-only tokens share no characters at all with `query`'s
            // letters, so they can't accidentally pick up a stray trigram
            // overlap the way two English words sometimes do.
            let symbolPath = "N000111.N222333"
            let text = "444555 666777 888999"
            #expect(Set(Tokenizer.tokenize(text: query)).isDisjoint(with: Tokenizer.tokenize(text: symbolPath + " " + text)))
            #expect(Trigram.dice(query: query, target: symbolPath + " " + text) == 0.0)

            let queryVector = try await embedder.embed([query])
            let semanticVector = try #require(queryVector.first)
            try await insertChunk(store: store, filePath: "Unrelated.swift", symbolPath: symbolPath, text: text, embedding: semanticVector)

            let corpus = SearchCorpus(store: store)
            let result = try await SearchCode.run(corpus: corpus, embedder: embedder, query: query)

            let hit = try #require(result.hits.first { $0.symbolPath == symbolPath })
            #expect(hit.hit.signals.bm25 == 0.0)
            #expect(hit.hit.signals.trigram == 0.0)
            #expect(abs(hit.hit.signals.cosine - 1.0) < 1e-5)
        }
    }

    @Test
    func symbolPathMatchOutranksBodyOnlyMatchInFusedOrdering() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            let query = "retryBackoffStrategy"

            // Strong: the query term appears in the *symbol path* (BM25 field
            // weight x5, plus an exact trigram match) as well as the body.
            try await insertChunk(
                store: store,
                filePath: "Strong.swift",
                symbolPath: "Network.retryBackoffStrategy",
                text: "func retryBackoffStrategy() { compute the retry backoff strategy }",
                embedding: nil
            )
            // Mediocre: the query term appears only once, in the body.
            try await insertChunk(
                store: store,
                filePath: "Mediocre.swift",
                symbolPath: "Helpers.doWork",
                text: "this helper mentions retryBackoffStrategy once in passing",
                embedding: nil
            )

            let corpus = SearchCorpus(store: store)
            let result = try await SearchCode.run(corpus: corpus, embedder: nil, query: query)

            let strongIndex = try #require(result.hits.firstIndex { $0.symbolPath == "Network.retryBackoffStrategy" })
            let mediocreIndex = try #require(result.hits.firstIndex { $0.symbolPath == "Helpers.doWork" })
            #expect(strongIndex < mediocreIndex)
            #expect(result.hits[strongIndex].hit.score > result.hits[mediocreIndex].hit.score)
        }
    }

    // MARK: - Generation staleness

    @Test
    func newlyIndexedChunkIsFoundOnTheNextSearchWithoutRecreatingTheCorpus() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("func retryWithBackoff() {}\n", to: "A.swift", in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)
            try await TreeSitterWorker.run(store: store, rootDirectory: root)

            // One SearchCorpus instance, reused across both searches below —
            // exactly the "no restart" shape the acceptance criterion
            // describes.
            let corpus = SearchCorpus(store: store)

            let firstResult = try await SearchCode.run(corpus: corpus, embedder: nil, query: "retryWithBackoffAgain")
            #expect(!firstResult.hits.contains { $0.symbolPath == "retryWithBackoffAgain" })

            try write("func retryWithBackoffAgain() {}\n", to: "B.swift", in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)
            try await TreeSitterWorker.run(store: store, rootDirectory: root)

            let secondResult = try await SearchCode.run(corpus: corpus, embedder: nil, query: "retryWithBackoffAgain")
            #expect(secondResult.hits.contains { $0.symbolPath == "retryWithBackoffAgain" })
        }
    }

    // MARK: - Degraded mode

    @Test
    func nilEmbedderReturnsKeywordRankedHitsAndIndexingProgress() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await insertChunk(
                store: store,
                filePath: "Config.swift",
                symbolPath: "Config.parseConfig",
                text: "parse the configuration file",
                embedding: nil
            )
            let corpus = SearchCorpus(store: store)

            let result = try await SearchCode.run(corpus: corpus, embedder: nil, query: "parse configuration")

            let hit = try #require(result.hits.first)
            #expect(hit.symbolPath == "Config.parseConfig")
            #expect(hit.hit.signals.cosine == 0.0)
            #expect(result.hits.allSatisfy { $0.hit.signals.cosine == 0.0 })

            let progress = try #require(result.indexingProgress)
            #expect(progress.totalChunks == 1)
            #expect(progress.embeddedChunks == 0)
        }
    }

    @Test
    func fullyEmbeddedCorpusHasNoIndexingProgressNote() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            let embedder = FakeEmbedder(dimension: Self.embeddingDimension)
            let vector = try #require(try await embedder.embed(["parse the configuration file"]).first)
            try await insertChunk(
                store: store,
                filePath: "Config.swift",
                symbolPath: "Config.parseConfig",
                text: "parse the configuration file",
                embedding: vector
            )
            let corpus = SearchCorpus(store: store)

            let result = try await SearchCode.run(corpus: corpus, embedder: embedder, query: "parse configuration")

            #expect(result.indexingProgress == nil)
        }
    }

    @Test
    func emptyCorpusReturnsNoHitsAndAnIndexingProgressNote() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            let corpus = SearchCorpus(store: store)

            let result = try await SearchCode.run(corpus: corpus, embedder: nil, query: "anything")

            #expect(result.hits.isEmpty)
            let progress = try #require(result.indexingProgress)
            #expect(progress.totalChunks == 0)
            #expect(progress.embeddedChunks == 0)
        }
    }
}
