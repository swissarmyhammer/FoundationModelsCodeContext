import Foundation
import GRDB
import Testing

@testable import CodeContextKit

/// Tests for `IndexAdmin`: `indexStatus()` count/percentage correctness
/// against `indexed_files`, and the `rebuildIndex(layer:)` → re-drain cycle
/// — including that a single-layer rebuild leaves the other two layers'
/// flags untouched.
struct IndexAdminTests {
    @Test
    func indexStatusOnFreshStoreIsAllZero() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)

            let status = try await IndexAdmin.indexStatus(store: store)

            #expect(status.totalFiles == 0)
            #expect(status.treeSitterIndexedFiles == 0)
            #expect(status.treeSitterIndexedPercent == 0.0)
            #expect(status.lspIndexedFiles == 0)
            #expect(status.lspIndexedPercent == 0.0)
            #expect(status.embeddedIndexedFiles == 0)
            #expect(status.embeddedIndexedPercent == 0.0)
        }
    }

    @Test
    func indexStatusReflectsTreeSitterDrainProgress() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("func a() {}\n", to: "A.swift", in: root)
            try write("func b() {}\n", to: "B.swift", in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)

            let before = try await IndexAdmin.indexStatus(store: store)
            #expect(before.totalFiles == 2)
            #expect(before.treeSitterIndexedFiles == 0)
            #expect(before.treeSitterIndexedPercent == 0.0)

            try await TreeSitterWorker.run(store: store, rootDirectory: root)

            let after = try await IndexAdmin.indexStatus(store: store)
            #expect(after.totalFiles == 2)
            #expect(after.treeSitterIndexedFiles == 2)
            #expect(after.treeSitterIndexedPercent == 100.0)
        }
    }

    @Test
    func rebuildIndexTreeSitterMarksFilesDirtyAndDrainRepopulatesChunks() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("func a() {}\n", to: "A.swift", in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)
            try await TreeSitterWorker.run(store: store, rootDirectory: root)
            #expect(try await store.drainTsDirty().isEmpty)

            let result = try await IndexAdmin.rebuildIndex(store: store, layer: .treeSitter)

            #expect(result.layer == .treeSitter)
            #expect(result.filesMarked == 1)
            #expect(try await store.drainTsDirty() == ["A.swift"])

            let statusAfterMark = try await IndexAdmin.indexStatus(store: store)
            #expect(statusAfterMark.treeSitterIndexedFiles == 0)

            let reprocessed = try await TreeSitterWorker.run(store: store, rootDirectory: root)
            #expect(reprocessed == 1)

            let symbolPaths: [String] = try await store.read { db in
                try String.fetchAll(db, sql: "SELECT symbol_path FROM ts_chunks")
            }
            #expect(symbolPaths == ["a"])

            let statusAfterDrain = try await IndexAdmin.indexStatus(store: store)
            #expect(statusAfterDrain.treeSitterIndexedFiles == 1)
            #expect(statusAfterDrain.treeSitterIndexedPercent == 100.0)
        }
    }

    @Test
    func rebuildIndexOnlyResetsRequestedLayerLeavesOthersUntouched() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await store.markDirty(filePath: "A.swift", contentHash: Data([1]), fileSize: 1)
            try await store.markIndexed(filePath: "A.swift", layer: .treeSitter)
            try await store.markIndexed(filePath: "A.swift", layer: .lsp)
            try await store.markIndexed(filePath: "A.swift", layer: .embedding)

            _ = try await IndexAdmin.rebuildIndex(store: store, layer: .treeSitter)

            #expect(try await store.drainTsDirty() == ["A.swift"])
            #expect(try await store.drainLspDirty().isEmpty)
            #expect(try await store.drainEmbeddingDirty().isEmpty)
        }
    }

    @Test
    func rebuildIndexAllResetsEveryLayer() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await store.markDirty(filePath: "A.swift", contentHash: Data([1]), fileSize: 1)
            try await store.markIndexed(filePath: "A.swift", layer: .treeSitter)
            try await store.markIndexed(filePath: "A.swift", layer: .lsp)
            try await store.markIndexed(filePath: "A.swift", layer: .embedding)

            let result = try await IndexAdmin.rebuildIndex(store: store, layer: .all)

            #expect(result.filesMarked == 1)
            #expect(try await store.drainTsDirty() == ["A.swift"])
            #expect(try await store.drainLspDirty() == ["A.swift"])
            #expect(try await store.drainEmbeddingDirty() == ["A.swift"])
        }
    }
}
