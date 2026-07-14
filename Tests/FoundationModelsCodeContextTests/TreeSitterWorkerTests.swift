import Foundation
import GRDB
import Testing

@testable import FoundationModelsCodeContext

/// Tests for `TreeSitterWorker`: the drain → chunk → write → mark cycle
/// against a real on-disk `Store`, and idempotency of a second drain with no
/// dirty files.
struct TreeSitterWorkerTests {
    @Test
    func runChunksDirtyFileAndMarksItIndexed() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("struct Struct {\n    func method() {}\n}\n", to: "Sample.swift", in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)

            let processed = try await TreeSitterWorker.run(store: store, rootDirectory: root)

            #expect(processed == 1)
            #expect(try await store.drainTsDirty().isEmpty)

            let symbolPaths: [String] = try await store.read { db in
                try String.fetchAll(db, sql: "SELECT symbol_path FROM ts_chunks ORDER BY symbol_path")
            }
            #expect(symbolPaths == ["Struct", "Struct.method"])
        }
    }

    @Test
    func runLeavesEmbeddingNullForEveryWrittenChunk() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("func topLevel() {}\n", to: "Sample.swift", in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)

            try await TreeSitterWorker.run(store: store, rootDirectory: root)

            let (totalChunks, nullEmbeddings) = try await store.read { db in
                let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ts_chunks") ?? 0
                let nulls = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ts_chunks WHERE embedding IS NULL") ?? 0
                return (total, nulls)
            }
            #expect(totalChunks == 1)
            #expect(nullEmbeddings == 1)
        }
    }

    @Test
    func secondRunWithNoDirtyFilesWritesNothing() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("func topLevel() {}\n", to: "Sample.swift", in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)
            try await TreeSitterWorker.run(store: store, rootDirectory: root)

            let firstRunChunkCount = try await store.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ts_chunks") ?? 0
            }

            let secondRunProcessed = try await TreeSitterWorker.run(store: store, rootDirectory: root)

            #expect(secondRunProcessed == 0)
            let secondRunChunkCount = try await store.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ts_chunks") ?? 0
            }
            #expect(secondRunChunkCount == firstRunChunkCount)
        }
    }

    @Test
    func runReplacesStaleChunksWhenAFileChanges() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("func original() {}\n", to: "Sample.swift", in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)
            try await TreeSitterWorker.run(store: store, rootDirectory: root)

            try write("func renamed() {}\n", to: "Sample.swift", in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)
            try await TreeSitterWorker.run(store: store, rootDirectory: root)

            let symbolPaths: [String] = try await store.read { db in
                try String.fetchAll(db, sql: "SELECT symbol_path FROM ts_chunks")
            }
            #expect(symbolPaths == ["renamed"])
        }
    }

    @Test
    func runProcessesEveryDirtyFileIndependentlyInOneDrain() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("func fromA() {}\n", to: "A.swift", in: root)
            try write("func fromB() {}\n", to: "B.swift", in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)

            let processed = try await TreeSitterWorker.run(store: store, rootDirectory: root)

            #expect(processed == 2)
            #expect(try await store.drainTsDirty().isEmpty)

            // Each file's DELETE (scoped by file_path) must not touch the
            // other file's rows, and each file's chunk must be attributed
            // to the right file_path.
            let rows: [[String]] = try await store.read { db in
                try Row.fetchAll(db, sql: "SELECT file_path, symbol_path FROM ts_chunks ORDER BY file_path")
                    .map { [$0["file_path"], $0["symbol_path"]] }
            }
            #expect(rows == [["A.swift", "fromA"], ["B.swift", "fromB"]])
        }
    }

    // MARK: - Path-traversal rejection

    @Test
    func runRejectsAPathTraversalRelativePathWithoutReadingTheFile() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            // A real, readable file sitting just outside the workspace root —
            // if `..` components in `file_path` were resolved instead of
            // rejected, this file would actually be read and chunked,
            // proving the traversal is live rather than coincidentally
            // absent (an outright-missing target would hit the pre-existing
            // "unreadable file" skip either way and wouldn't discriminate).
            try write("func secret() {}\n", to: "../secret.swift", in: root)
            // A `file_path` that escapes the workspace root should never be
            // resolved against disk, even though `drainTsDirty` will happily
            // return whatever string is stored in `indexed_files.file_path`.
            try await store.markDirty(filePath: "../secret.swift", contentHash: Data("../secret.swift".utf8), fileSize: 1)

            let processed = try await TreeSitterWorker.run(store: store, rootDirectory: root)

            #expect(processed == 1)
            #expect(try await store.drainTsDirty().isEmpty)
            let chunkCount = try await store.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ts_chunks") ?? 0
            }
            #expect(chunkCount == 0, "the out-of-root file's chunks must never be persisted")
        }
    }

    @Test
    func runMarksFileIndexedEvenWhenItHasNoChunkableNodes() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("// just a comment\n", to: "Sample.swift", in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)

            let processed = try await TreeSitterWorker.run(store: store, rootDirectory: root)

            #expect(processed == 1)
            #expect(try await store.drainTsDirty().isEmpty)
            let chunkCount = try await store.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ts_chunks") ?? 0
            }
            #expect(chunkCount == 0)
        }
    }
}
