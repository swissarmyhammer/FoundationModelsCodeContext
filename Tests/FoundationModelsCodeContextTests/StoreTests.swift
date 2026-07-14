import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// Tests for `Store`: fresh-open schema/gitignore bootstrap, the
/// dirty-flag drain/mark cycle, and FK-cascade delete of a file's
/// chunks/symbols/edges.
struct StoreTests {
    @Test
    func freshOpenCreatesDatabaseAndGitignore() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)

            let dbPath = root.appendingPathComponent(".code-context/kit.db").path
            let gitignorePath = root.appendingPathComponent(".code-context/.gitignore").path
            #expect(FileManager.default.fileExists(atPath: dbPath))
            #expect(FileManager.default.fileExists(atPath: gitignorePath))

            let gitignoreContents = try String(contentsOfFile: gitignorePath, encoding: .utf8)
            #expect(gitignoreContents == "*\n")

            #expect(store.rootDirectory == root)
            #expect(store.databaseURL.path == dbPath)
        }
    }

    @Test
    func freshOpenUsesWALJournalMode() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            let journalMode = try await store.read { db in
                try String.fetchOne(db, sql: "PRAGMA journal_mode")
            }
            #expect(journalMode == "wal")
        }
    }

    @Test
    func freshOpenRunsAllMigrations() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)

            let tableNames: Set<String> = try await store.read { db in
                Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
            }

            #expect(tableNames.isSuperset(of: [
                "indexed_files", "ts_chunks", "lsp_symbols", "lsp_call_edges", "meta",
            ]))
        }
    }

    @Test
    func dirtyFlagDrainAndMarkCycle() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await store.markDirty(filePath: "Sources/A.swift", contentHash: Data([1, 2, 3]), fileSize: 42)

            #expect(try await store.drainTsDirty() == ["Sources/A.swift"])
            #expect(try await store.drainLspDirty() == ["Sources/A.swift"])
            #expect(try await store.drainEmbeddingDirty() == ["Sources/A.swift"])

            try await store.markIndexed(filePath: "Sources/A.swift", layer: .treeSitter)
            #expect(try await store.drainTsDirty().isEmpty)
            #expect(try await store.drainLspDirty() == ["Sources/A.swift"])
            #expect(try await store.drainEmbeddingDirty() == ["Sources/A.swift"])

            try await store.markIndexed(filePath: "Sources/A.swift", layer: .lsp)
            #expect(try await store.drainLspDirty().isEmpty)
            #expect(try await store.drainEmbeddingDirty() == ["Sources/A.swift"])

            try await store.markIndexed(filePath: "Sources/A.swift", layer: .embedding)
            #expect(try await store.drainEmbeddingDirty().isEmpty)
        }
    }

    @Test
    func markDirtyResetsFlagsOnChangedFile() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await store.markDirty(filePath: "Sources/A.swift", contentHash: Data([1]), fileSize: 1)
            try await store.markIndexed(filePath: "Sources/A.swift", layer: .treeSitter)
            try await store.markIndexed(filePath: "Sources/A.swift", layer: .lsp)
            try await store.markIndexed(filePath: "Sources/A.swift", layer: .embedding)

            #expect(try await store.drainTsDirty().isEmpty)
            #expect(try await store.drainLspDirty().isEmpty)

            // File changed on disk: markDirty again re-dirties every layer.
            try await store.markDirty(filePath: "Sources/A.swift", contentHash: Data([9, 9]), fileSize: 2)

            #expect(try await store.drainTsDirty() == ["Sources/A.swift"])
            #expect(try await store.drainLspDirty() == ["Sources/A.swift"])
        }
    }

    @Test
    func embedderDimensionRoundTrips() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            #expect(try await store.embedderDimension() == nil)

            try await store.setEmbedderDimension(1024)
            #expect(try await store.embedderDimension() == 1024)

            try await store.setEmbedderDimension(768)
            #expect(try await store.embedderDimension() == 768)
        }
    }

    /// Row counts across the three child tables, used to assert
    /// FK-cascade behavior before/after deleting an `indexed_files` row.
    private struct ChildRowCounts: Equatable {
        var chunks: Int
        var symbols: Int
        var edges: Int
    }

    @Test
    func foreignKeyCascadeDeletesChunksSymbolsAndEdges() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await store.markDirty(filePath: "Sources/A.swift", contentHash: Data([1]), fileSize: 1)
            // A second, unrelated file with its own chunk/symbol/edge rows —
            // proves the delete below is scoped to Sources/A.swift and
            // doesn't collaterally wipe other files' data.
            try await store.markDirty(filePath: "Sources/B.swift", contentHash: Data([2]), fileSize: 1)

            try await store.write { db in
                try db.execute(sql: """
                INSERT INTO ts_chunks (file_path, start_byte, end_byte, start_line, end_line, text, symbol_path, kind)
                VALUES ('Sources/A.swift', 0, 10, 1, 2, 'func a() {}', 'A.a', 'function')
                """)
                try db.execute(sql: """
                INSERT INTO lsp_symbols (id, name, kind, file_path, start_line, start_column, end_line, end_column, detail)
                VALUES (1, 'a', 'function', 'Sources/A.swift', 1, 0, 2, 1, NULL)
                """)
                try db.execute(sql: """
                INSERT INTO lsp_symbols (id, name, kind, file_path, start_line, start_column, end_line, end_column, detail)
                VALUES (2, 'b', 'function', 'Sources/A.swift', 3, 0, 4, 1, NULL)
                """)
                try db.execute(sql: """
                INSERT INTO lsp_call_edges (caller_id, callee_id, file_path, from_ranges, source)
                VALUES (1, 2, 'Sources/A.swift', '[]', 'lsp')
                """)

                try db.execute(sql: """
                INSERT INTO ts_chunks (file_path, start_byte, end_byte, start_line, end_line, text, symbol_path, kind)
                VALUES ('Sources/B.swift', 0, 10, 1, 2, 'func c() {}', 'B.c', 'function')
                """)
                try db.execute(sql: """
                INSERT INTO lsp_symbols (id, name, kind, file_path, start_line, start_column, end_line, end_column, detail)
                VALUES (3, 'c', 'function', 'Sources/B.swift', 1, 0, 2, 1, NULL)
                """)
                try db.execute(sql: """
                INSERT INTO lsp_symbols (id, name, kind, file_path, start_line, start_column, end_line, end_column, detail)
                VALUES (4, 'd', 'function', 'Sources/B.swift', 3, 0, 4, 1, NULL)
                """)
                try db.execute(sql: """
                INSERT INTO lsp_call_edges (caller_id, callee_id, file_path, from_ranges, source)
                VALUES (3, 4, 'Sources/B.swift', '[]', 'treesitter')
                """)
            }

            let before = try await store.read { db in
                try ChildRowCounts(
                    chunks: Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ts_chunks") ?? 0,
                    symbols: Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lsp_symbols") ?? 0,
                    edges: Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lsp_call_edges") ?? 0
                )
            }
            #expect(before == ChildRowCounts(chunks: 2, symbols: 4, edges: 2))

            try await store.write { db in
                try db.execute(sql: "DELETE FROM indexed_files WHERE file_path = 'Sources/A.swift'")
            }

            let after = try await store.read { db in
                try ChildRowCounts(
                    chunks: Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ts_chunks") ?? 0,
                    symbols: Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lsp_symbols") ?? 0,
                    edges: Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lsp_call_edges") ?? 0
                )
            }
            // Sources/A.swift's rows are gone; Sources/B.swift's one
            // chunk, two symbols, and one edge survive untouched.
            #expect(after == ChildRowCounts(chunks: 1, symbols: 2, edges: 1))

            let survivingFilePaths = try await store.read { db in
                try String.fetchAll(db, sql: "SELECT DISTINCT file_path FROM ts_chunks")
            }
            #expect(survivingFilePaths == ["Sources/B.swift"])
        }
    }
}

/// Tests for `EmbeddingCodec`: little-endian `[Float]` ⇄ `Data` round-trip.
struct EmbeddingCodecTests {
    @Test
    func roundTripsArbitraryVector() {
        let vector: [Float] = [0.0, 1.5, -3.25, .pi, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, .leastNonzeroMagnitude]
        let data = EmbeddingCodec.encode(vector)
        #expect(EmbeddingCodec.decode(data) == vector)
    }

    @Test
    func roundTripsEmptyVector() {
        let data = EmbeddingCodec.encode([])
        #expect(data.isEmpty)
        #expect(EmbeddingCodec.decode(data).isEmpty)
    }

    @Test
    func roundTrips1024DimensionVector() {
        let vector = (0..<1024).map { _ in Float.random(in: -1000...1000) }
        let data = EmbeddingCodec.encode(vector)
        #expect(data.count == 1024 * MemoryLayout<Float>.size)
        #expect(EmbeddingCodec.decode(data) == vector)
    }

    @Test
    func encodesLittleEndian() {
        // Float32 1.0 has bit pattern 0x3F800000; little-endian byte order
        // is the least-significant byte first.
        let data = EmbeddingCodec.encode([Float(1.0)])
        #expect(Array(data) == [0x00, 0x00, 0x80, 0x3F])
    }

    @Test
    func roundTripsNonFiniteAndSignedZeroBitPatterns() {
        // Plain `==` on Float is false for NaN != NaN, so this compares
        // `bitPattern`s directly to prove the codec is exact — including
        // the sign bit on zero, which `0.0 == -0.0` would mask.
        let vector: [Float] = [.nan, .infinity, -.infinity, -0.0, 0.0]
        let data = EmbeddingCodec.encode(vector)
        let decoded = EmbeddingCodec.decode(data)

        #expect(decoded.map(\.bitPattern) == vector.map(\.bitPattern))
    }
}
