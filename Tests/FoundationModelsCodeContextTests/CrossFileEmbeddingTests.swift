import Foundation
import GRDB
import Testing

@testable import FoundationModelsCodeContext

/// Tests for the `embed(texts:)` calls of `TreeSitterWorker` that hold the
/// dirty chunks of more than one file.
///
/// Each test chunks the fixture first, with no embedder, and reads the chunk
/// count of each file from the store. Thus the tests do not depend on how many
/// chunks the chunker makes of one function.
struct CrossFileEmbeddingTests {
    /// The dimension of the fake embedding vectors.
    private static let dimension = 8

    /// The number of functions in each fixture file. Two functions give two
    /// chunks or more, thus a call can end inside a file.
    private static let functionsInEachFile = 2

    /// The paths of the fixture files. The drain gives them in path order.
    private static let filePaths = ["A.swift", "B.swift", "C.swift"]

    /// The number of the second chunk-batch call of a pass.
    private static let secondCallNumber = 2

    /// Writes one Swift file with `functionsInEachFile` functions for each path
    /// of `paths` into `root`, records the files as dirty in `store`, and
    /// chunks them with no embedder.
    ///
    /// - Parameters:
    ///   - paths: The relative paths of the files to write.
    ///   - root: The workspace root.
    ///   - store: The index store of the workspace.
    /// - Returns: The number of chunks of each file. Each file has the same
    ///   shape, thus each file has the same number of chunks.
    private static func prepareChunkedFixture(paths: [String], in root: URL, store: Store) async throws -> Int {
        for path in paths {
            let stem = path.replacingOccurrences(of: ".swift", with: "")
            let source = (0..<functionsInEachFile)
                .map { index in "func function\(stem)\(index)() -> Int {\n    return \(index)\n}\n" }
                .joined(separator: "\n")
            try write(source, to: path, in: root)
        }
        _ = try await Reconciler.reconcile(store: store, rootDirectory: root)
        try await TreeSitterWorker.run(store: store, rootDirectory: root)
        let (chunkedFileCount, chunkCounts) = try await store.read { db in
            let fileCount = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT file_path) FROM ts_chunks") ?? 0
            let counts = try Int.fetchSet(db, sql: "SELECT COUNT(*) FROM ts_chunks GROUP BY file_path")
            return (fileCount, counts)
        }
        #expect(chunkedFileCount == paths.count)
        #expect(chunkCounts.count == 1)
        let chunksInEachFile = try #require(chunkCounts.first)
        #expect(chunksInEachFile >= functionsInEachFile)
        return chunksInEachFile
    }

    /// Reads the number of chunks of the file at `path` that have an embedding.
    private static func embeddedChunkCount(of path: String, in store: Store) async throws -> Int {
        try await store.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM ts_chunks WHERE file_path = ? AND embedding IS NOT NULL",
                arguments: [path]
            ) ?? 0
        }
    }

    /// Reads the `embedded` flag of the file at `path`.
    private static func isMarkedEmbedded(_ path: String, in store: Store) async throws -> Bool {
        try await store.read { db in
            try Bool.fetchOne(db, sql: "SELECT embedded FROM indexed_files WHERE file_path = ?", arguments: [path]) ?? false
        }
    }

    /// Runs one index pass with a `GatedEmbedder` that fails on the calls of
    /// `failingCallNumbers`.
    ///
    /// - Returns: The size of each chunk-batch call of the pass, in call order.
    private static func embeddingPass(
        store: Store,
        root: URL,
        batchSize: Int,
        failingCallNumbers: Set<Int> = []
    ) async throws -> [Int] {
        let log = EmbedCallLog()
        try await TreeSitterWorker.run(
            store: store,
            rootDirectory: root,
            embedder: GatedEmbedder(vectorLength: dimension, log: log, failingCallNumbers: failingCallNumbers),
            embeddingBatchSize: batchSize
        )
        return await log.batchSizes
    }

    @Test
    func oneCallHoldsTheChunksOfSeveralFiles() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            let chunksInEachFile = try await Self.prepareChunkedFixture(paths: Self.filePaths, in: root, store: store)
            let totalChunks = chunksInEachFile * Self.filePaths.count

            let batchSizes = try await Self.embeddingPass(store: store, root: root, batchSize: totalChunks)

            #expect(batchSizes == [totalChunks])
            for path in Self.filePaths {
                #expect(try await Self.isMarkedEmbedded(path, in: store))
                #expect(try await Self.embeddedChunkCount(of: path, in: store) == chunksInEachFile)
            }
        }
    }

    @Test
    func aFileIsMarkedEmbeddedOnlyWhenEachOfItsChunksHasAVector() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            let paths = ["A.swift", "B.swift"]
            let chunksInEachFile = try await Self.prepareChunkedFixture(paths: paths, in: root, store: store)

            // The first call holds all the chunks of A.swift and the first
            // chunk of B.swift. The second call holds the other chunks of
            // B.swift, and it fails.
            let batchSizes = try await Self.embeddingPass(
                store: store,
                root: root,
                batchSize: chunksInEachFile + 1,
                failingCallNumbers: [Self.secondCallNumber]
            )

            #expect(batchSizes == [chunksInEachFile + 1, chunksInEachFile - 1])
            #expect(try await Self.isMarkedEmbedded("A.swift", in: store))
            #expect(try await Self.embeddedChunkCount(of: "A.swift", in: store) == chunksInEachFile)
            #expect(try await !Self.isMarkedEmbedded("B.swift", in: store))
            #expect(try await Self.embeddedChunkCount(of: "B.swift", in: store) == 0)
        }
    }

    @Test
    func aFailedCallSkipsOnlyTheFilesOfThatCallAndTheNextPassEmbedsThem() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            let chunksInEachFile = try await Self.prepareChunkedFixture(paths: Self.filePaths, in: root, store: store)
            let batchSize = chunksInEachFile + 1

            // The first call holds A.swift and the first chunk of B.swift, and
            // it fails. The calls after it hold the other chunks of B.swift and
            // all of C.swift.
            _ = try await Self.embeddingPass(store: store, root: root, batchSize: batchSize, failingCallNumbers: [1])

            let skippedPaths = ["A.swift", "B.swift"]
            for path in skippedPaths {
                #expect(try await !Self.isMarkedEmbedded(path, in: store))
                #expect(try await Self.embeddedChunkCount(of: path, in: store) == 0)
            }
            #expect(try await Self.isMarkedEmbedded("C.swift", in: store))
            #expect(try await Self.embeddedChunkCount(of: "C.swift", in: store) == chunksInEachFile)

            let nextPassBatchSizes = try await Self.embeddingPass(store: store, root: root, batchSize: batchSize)

            #expect(nextPassBatchSizes.reduce(0, +) == skippedPaths.count * chunksInEachFile)
            for path in Self.filePaths {
                #expect(try await Self.isMarkedEmbedded(path, in: store))
                #expect(try await Self.embeddedChunkCount(of: path, in: store) == chunksInEachFile)
            }
        }
    }
}
