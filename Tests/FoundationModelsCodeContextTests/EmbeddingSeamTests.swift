import Foundation
import GRDB
import Testing

@testable import FoundationModelsCodeContext

/// Tests for the embedding seam: `FakeEmbedder` determinism, and
/// `TreeSitterWorker`'s optional embedding integration — happy path,
/// graceful skip on a throwing embedder, and dimension-mismatch re-embed
/// via the `meta` table.
struct EmbeddingSeamTests {
    private struct SampleError: Error {}

    @Test
    func fakeEmbedderProducesTheSameVectorForTheSameTextEveryCall() async throws {
        let embedder = FakeEmbedder(dimension: 16)

        let first = try await embedder.embed(["func add() {}"])
        let second = try await embedder.embed(["func add() {}"])

        #expect(first == second)
    }

    @Test
    func fakeEmbedderProducesDifferentVectorsForDifferentText() async throws {
        let embedder = FakeEmbedder(dimension: 16)

        let vectors = try await embedder.embed(["func add() {}", "func subtract() {}"])

        #expect(vectors[0] != vectors[1])
    }

    @Test
    func fakeEmbedderProducesL2NormalizedVectorsOfTheConfiguredDimension() async throws {
        let embedder = FakeEmbedder(dimension: 12)

        let vectors = try await embedder.embed(["func add() {}", "struct Sample {}"])

        for vector in vectors {
            #expect(vector.count == 12)
            let magnitude = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
            #expect(abs(magnitude - 1) < 0.0001)
        }
    }

    @Test
    func workerWithFakeEmbedderWritesNormalizedVectorsAndMarksEmbedded() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("struct Struct {\n    func method() {}\n}\n", to: "Sample.swift", in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)

            try await TreeSitterWorker.run(store: store, rootDirectory: root, embedder: FakeEmbedder(dimension: 8))

            let embeddings: [Data] = try await store.read { db in
                try Data.fetchAll(db, sql: "SELECT embedding FROM ts_chunks ORDER BY id")
            }
            #expect(embeddings.count == 2)
            for embedding in embeddings {
                let vector = EmbeddingCodec.decode(embedding)
                #expect(vector.count == 8)
                let magnitude = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
                #expect(abs(magnitude - 1) < 0.0001)
            }

            let embeddedFlag: Bool = try await store.read { db in
                try Bool.fetchOne(db, sql: "SELECT embedded FROM indexed_files WHERE file_path = ?", arguments: ["Sample.swift"]) ?? false
            }
            #expect(embeddedFlag)
        }
    }

    @Test
    func workerWithThrowingEmbedderLeavesChunksWithNullEmbeddingAndUnmarked() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("func topLevel() {}\n", to: "Sample.swift", in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)

            let embedder = FakeEmbedder(dimension: 8, failure: SampleError())
            try await TreeSitterWorker.run(store: store, rootDirectory: root, embedder: embedder)

            let (totalChunks, nullEmbeddings) = try await store.read { db in
                let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ts_chunks") ?? 0
                let nulls = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ts_chunks WHERE embedding IS NULL") ?? 0
                return (total, nulls)
            }
            #expect(totalChunks == 1)
            #expect(nullEmbeddings == 1)

            let embeddedFlag: Bool = try await store.read { db in
                try Bool.fetchOne(db, sql: "SELECT embedded FROM indexed_files WHERE file_path = ?", arguments: ["Sample.swift"]) ?? true
            }
            #expect(embeddedFlag == false)
        }
    }

    @Test
    func workerWithNoEmbedderLeavesChunksUnembedded() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("func topLevel() {}\n", to: "Sample.swift", in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)

            try await TreeSitterWorker.run(store: store, rootDirectory: root)

            let embeddedFlag: Bool = try await store.read { db in
                try Bool.fetchOne(db, sql: "SELECT embedded FROM indexed_files WHERE file_path = ?", arguments: ["Sample.swift"]) ?? true
            }
            #expect(embeddedFlag == false)
        }
    }

    @Test
    func rechunkingAnAlreadyEmbeddedFileResetsTheEmbeddedFlag() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("func original() {}\n", to: "Sample.swift", in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)
            try await TreeSitterWorker.run(store: store, rootDirectory: root, embedder: FakeEmbedder(dimension: 8))

            let embeddedBeforeRechunk: Bool = try await store.read { db in
                try Bool.fetchOne(db, sql: "SELECT embedded FROM indexed_files WHERE file_path = ?", arguments: ["Sample.swift"]) ?? false
            }
            #expect(embeddedBeforeRechunk)

            // Simulate a re-chunk trigger that dirties only the tree-sitter
            // layer, bypassing `Store.markDirty` (which would already reset
            // `embedded` itself). This isolates `writeChunks`'s own
            // responsibility for keeping `embedded` consistent with the rows
            // it rewrites, independent of how the file became ts-dirty.
            try await store.write { db in
                try db.execute(sql: "UPDATE indexed_files SET ts_indexed = 0 WHERE file_path = ?", arguments: ["Sample.swift"])
            }

            try await TreeSitterWorker.run(store: store, rootDirectory: root)

            let embeddedAfterRechunk: Bool = try await store.read { db in
                try Bool.fetchOne(db, sql: "SELECT embedded FROM indexed_files WHERE file_path = ?", arguments: ["Sample.swift"]) ?? true
            }
            #expect(embeddedAfterRechunk == false)
        }
    }

    @Test
    func changingEmbedderDimensionBetweenRunsTriggersFullReembed() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("func topLevel() {}\n", to: "Sample.swift", in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)

            try await TreeSitterWorker.run(store: store, rootDirectory: root, embedder: FakeEmbedder(dimension: 8))

            let firstPassDimension: Int = try await store.read { db in
                let embedding = try Data.fetchOne(db, sql: "SELECT embedding FROM ts_chunks LIMIT 1")
                return embedding.map { EmbeddingCodec.decode($0).count } ?? 0
            }
            #expect(firstPassDimension == 8)

            // No new dirty tree-sitter files this pass — only the embedder's
            // dimension changed. The worker must still detect the mismatch
            // against the stored `meta` dimension and fully re-embed.
            try await TreeSitterWorker.run(store: store, rootDirectory: root, embedder: FakeEmbedder(dimension: 16))

            let secondPassDimension: Int = try await store.read { db in
                let embedding = try Data.fetchOne(db, sql: "SELECT embedding FROM ts_chunks LIMIT 1")
                return embedding.map { EmbeddingCodec.decode($0).count } ?? 0
            }
            #expect(secondPassDimension == 16)

            let storedDimension = try await store.embedderDimension()
            #expect(storedDimension == 16)
        }
    }
}
