import Foundation
import GRDB
import FoundationModelsRanker
import Testing

@testable import FoundationModelsCodeContext

/// Re-chunks `filePath` the way `TreeSitterWorker.writeChunks` does — deletes
/// the file's existing `ts_chunks` rows and inserts fresh ones (with new
/// autoincrement ids) — so tests can drive a real incremental file re-index,
/// not just an append.
///
/// - Parameters:
///   - store: the store to write into.
///   - filePath: the file whose chunks to replace.
///   - chunks: the replacement chunks, each a `(symbolPath, text, embedding)`
///     triple.
private func reindexFile(
    store: Store,
    filePath: String,
    chunks: [(symbolPath: String, text: String, embedding: [Float]?)]
) async throws {
    try await store.write { db in
        try db.execute(sql: "DELETE FROM ts_chunks WHERE file_path = ?", arguments: [filePath])
        for (index, chunk) in chunks.enumerated() {
            try db.execute(
                sql: """
                INSERT INTO ts_chunks (file_path, start_byte, end_byte, start_line, end_line, text, symbol_path, kind, embedding)
                VALUES (?, 0, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    filePath, chunk.text.utf8.count, index, index + 1, chunk.text, chunk.symbolPath,
                    SymbolMetaType.function.rawValue, chunk.embedding.map(EmbeddingCodec.encode),
                ]
            )
        }
    }
}

/// Tests for `SearchCorpus`'s incremental, per-file re-index: editing one file
/// re-tokenizes and re-decodes only that file's chunks (never the whole
/// corpus), and yields search results and BM25 globals identical to a
/// from-scratch snapshot of the same store state.
struct SearchCorpusIncrementalTests {
    private static let embeddingDimension = 16

    /// Materializes a small many-file corpus, every chunk embedded, so the
    /// incremental-vs-wholesale comparisons below start from a fully-loaded
    /// cache.
    private static func seedManyFileCorpus(store: Store) async throws {
        let embedder = FakeEmbedder(dimension: embeddingDimension)
        let fixtures: [(file: String, symbol: String, text: String)] = [
            ("Alpha.swift", "Alpha.parseConfig", "parse the configuration file for alpha"),
            ("Beta.swift", "Beta.retryBackoff", "apply retry backoff strategy before requesting again"),
            ("Gamma.swift", "Gamma.renderView", "render the main view hierarchy on screen"),
            ("Delta.swift", "Delta.hashInput", "compute a stable hash of the input bytes"),
        ]
        for fixture in fixtures {
            let vector = try #require(try await embedder.embed([fixture.text]).first)
            try await insertChunk(
                store: store, filePath: fixture.file, symbolPath: fixture.symbol, text: fixture.text, embedding: vector
            )
        }
    }

    // MARK: - Equivalence: incremental vs. wholesale

    @Test
    func searchResultsAfterIncrementalEditMatchAFromScratchSnapshot() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedManyFileCorpus(store: store)
            let embedder = FakeEmbedder(dimension: Self.embeddingDimension)

            // Warm the incremental corpus's cache on the seeded state.
            let incremental = SearchCorpus(store: store)
            _ = try await incremental.snapshot()

            // Edit exactly one file: new symbol/text, re-embedded.
            let newText = "look up the account balance ledger entry"
            let newVector = try #require(try await embedder.embed([newText]).first)
            try await reindexFile(
                store: store, filePath: "Beta.swift",
                chunks: [(symbolPath: "Beta.accountBalance", text: newText, embedding: newVector)]
            )

            // A fresh corpus over the SAME post-edit store state is the
            // from-scratch oracle.
            let fromScratch = SearchCorpus(store: store)

            for query in ["account balance ledger", "parse configuration", "retry backoff strategy", "render view", "Beta.accountBalance"] {
                let incrementalResult = try await SearchCode.run(corpus: incremental, embedder: embedder, query: query)
                let scratchResult = try await SearchCode.run(corpus: fromScratch, embedder: embedder, query: query)

                #expect(incrementalResult.hits.map(\.symbolPath) == scratchResult.hits.map(\.symbolPath))
                for (incrementalHit, scratchHit) in zip(incrementalResult.hits, scratchResult.hits) {
                    #expect(incrementalHit.symbolPath == scratchHit.symbolPath)
                    #expect(abs(incrementalHit.hit.score - scratchHit.hit.score) < 1e-9)
                    // BM25 globals (idf/avgdl) surface through the raw bm25
                    // signal — equal signals mean equal globals.
                    #expect(abs(incrementalHit.hit.signals.bm25 - scratchHit.hit.signals.bm25) < 1e-9)
                    #expect(abs(incrementalHit.hit.signals.trigram - scratchHit.hit.signals.trigram) < 1e-9)
                    #expect(abs(incrementalHit.hit.signals.cosine - scratchHit.hit.signals.cosine) < 1e-9)
                }
            }
        }
    }

    @Test
    func incrementalSnapshotChunkIdsMatchAFromScratchSnapshot() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedManyFileCorpus(store: store)

            let incremental = SearchCorpus(store: store)
            _ = try await incremental.snapshot()

            try await reindexFile(
                store: store, filePath: "Gamma.swift",
                chunks: [
                    (symbolPath: "Gamma.renderView", text: "render the main view hierarchy on screen", embedding: nil),
                    (symbolPath: "Gamma.layout", text: "compute the layout constraints for each subview", embedding: nil),
                ]
            )

            let incrementalSnapshot = try await incremental.snapshot()
            let fromScratchSnapshot = try await SearchCorpus(store: store).snapshot()

            #expect(incrementalSnapshot.chunkIDs == fromScratchSnapshot.chunkIDs)
            #expect(incrementalSnapshot.symbolPaths == fromScratchSnapshot.symbolPaths)
            #expect(incrementalSnapshot.texts == fromScratchSnapshot.texts)
            #expect(incrementalSnapshot.embeddedFlags == fromScratchSnapshot.embeddedFlags)
            #expect(incrementalSnapshot.embeddingMatrix == fromScratchSnapshot.embeddingMatrix)
        }
    }

    // MARK: - Perf guard: only the edited file is re-tokenized / re-decoded

    @Test
    func editingOneFileReTokenizesOnlyThatFilesChunks() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedManyFileCorpus(store: store)

            let corpus = SearchCorpus(store: store)
            // Cold start tokenizes every chunk (four files, one chunk each).
            _ = try await corpus.snapshot()
            #expect(await corpus.lastBuildReTokenizedChunkCount == 4)

            // Re-index one file with two chunks.
            try await reindexFile(
                store: store, filePath: "Delta.swift",
                chunks: [
                    (symbolPath: "Delta.hashInput", text: "compute a stable hash of the input bytes", embedding: nil),
                    (symbolPath: "Delta.hashSalt", text: "mix a salt into the running hash accumulator", embedding: nil),
                ]
            )

            let snapshot = try await corpus.snapshot()
            // Only the two edited chunks were re-tokenized — the other three
            // files' chunks were reused from cache.
            #expect(await corpus.lastBuildReTokenizedChunkCount == 2)
            #expect(snapshot.chunkCount == 5)
        }
    }

    @Test
    func aGenerationBumpThatLeavesChunksUnchangedReTokenizesNothing() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedManyFileCorpus(store: store)

            let corpus = SearchCorpus(store: store)
            _ = try await corpus.snapshot()

            // A write that bumps `generation` but touches no `ts_chunks` row
            // (flipping an indexed_files flag) must not re-tokenize anything.
            try await store.markIndexed(filePath: "Alpha.swift", layer: .lsp)

            _ = try await corpus.snapshot()
            #expect(await corpus.lastBuildReTokenizedChunkCount == 0)
        }
    }

    // MARK: - Cosine: matrix repacked from persisted vectors, edited file only

    @Test
    func editingOneFileReDecodesOnlyThatFilesEmbeddingsAndPreservesOthers() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedManyFileCorpus(store: store)
            let embedder = FakeEmbedder(dimension: Self.embeddingDimension)

            let corpus = SearchCorpus(store: store)
            let before = try await corpus.snapshot()
            #expect(await corpus.lastBuildReDecodedChunkCount == 4)

            // Capture Alpha.swift's embedding row before the unrelated edit.
            let alphaIndexBefore = try #require(before.symbolPaths.firstIndex(of: "Alpha.parseConfig"))
            let alphaRowBefore = Array(
                before.embeddingMatrix[
                    (alphaIndexBefore * before.embeddingDimension)..<((alphaIndexBefore + 1) * before.embeddingDimension)
                ]
            )

            let newText = "serialize the message envelope to wire format"
            let newVector = try #require(try await embedder.embed([newText]).first)
            try await reindexFile(
                store: store, filePath: "Delta.swift",
                chunks: [(symbolPath: "Delta.serialize", text: newText, embedding: newVector)]
            )

            let after = try await corpus.snapshot()
            // Only Delta.swift's single embedded chunk was decoded this pass.
            #expect(await corpus.lastBuildReDecodedChunkCount == 1)

            // Alpha's persisted vector survived the repack untouched.
            let alphaIndexAfter = try #require(after.symbolPaths.firstIndex(of: "Alpha.parseConfig"))
            let alphaRowAfter = Array(
                after.embeddingMatrix[
                    (alphaIndexAfter * after.embeddingDimension)..<((alphaIndexAfter + 1) * after.embeddingDimension)
                ]
            )
            #expect(alphaRowAfter == alphaRowBefore)

            // Delta's new vector is present and matches the freshly embedded one.
            let deltaIndexAfter = try #require(after.symbolPaths.firstIndex(of: "Delta.serialize"))
            let deltaRowAfter = Array(
                after.embeddingMatrix[
                    (deltaIndexAfter * after.embeddingDimension)..<((deltaIndexAfter + 1) * after.embeddingDimension)
                ]
            )
            #expect(deltaRowAfter == newVector)
        }
    }

    @Test
    func inPlaceEmbeddingDimensionChangeIsPickedUpIncrementally() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedManyFileCorpus(store: store)

            let incremental = SearchCorpus(store: store)
            let before = try await incremental.snapshot()
            #expect(before.embeddingDimension == Self.embeddingDimension)

            // Reproduce `TreeSitterWorker.reconcileEmbedderDimension` + re-embed:
            // every chunk's embedding is replaced IN PLACE (same `ts_chunks.id`,
            // still non-NULL) with a wider, new-dimension vector. A bare
            // `hasEmbedding` signature would see no change here and keep serving
            // the stale 16-dim vectors; the byte-length signature catches it.
            let widerDimension = Self.embeddingDimension * 2
            let widerEmbedder = FakeEmbedder(dimension: widerDimension)
            let chunkIds: [Int64] = try await store.read { db in
                try Int64.fetchAll(db, sql: "SELECT id FROM ts_chunks ORDER BY id")
            }
            let chunkTexts: [String] = try await store.read { db in
                try String.fetchAll(db, sql: "SELECT text FROM ts_chunks ORDER BY id")
            }
            // Embed outside the (synchronous) write transaction, then apply.
            let widerVectors = try await widerEmbedder.embed(chunkTexts)
            let encoded = zip(chunkIds, widerVectors).map { (id: $0, blob: EmbeddingCodec.encode($1)) }
            try await store.write { db in
                for entry in encoded {
                    try db.execute(
                        sql: "UPDATE ts_chunks SET embedding = ? WHERE id = ?",
                        arguments: [entry.blob, entry.id]
                    )
                }
            }

            let after = try await incremental.snapshot()
            let fromScratch = try await SearchCorpus(store: store).snapshot()

            #expect(after.embeddingDimension == widerDimension)
            #expect(after.embeddingDimension == fromScratch.embeddingDimension)
            #expect(after.embeddingMatrix == fromScratch.embeddingMatrix)
            #expect(after.embeddedFlags == fromScratch.embeddedFlags)
        }
    }

    // MARK: - Deletion

    @Test
    func deletingAFileDropsItsChunksFromTheIncrementalSnapshot() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await Self.seedManyFileCorpus(store: store)

            let corpus = SearchCorpus(store: store)
            _ = try await corpus.snapshot()

            try await store.deleteFile(filePath: "Beta.swift")

            let snapshot = try await corpus.snapshot()
            #expect(snapshot.chunkCount == 3)
            #expect(!snapshot.symbolPaths.contains("Beta.retryBackoff"))
            #expect(await corpus.lastBuildReTokenizedChunkCount == 0)

            let fromScratch = try await SearchCorpus(store: store).snapshot()
            #expect(snapshot.chunkIDs == fromScratch.chunkIDs)
        }
    }
}
