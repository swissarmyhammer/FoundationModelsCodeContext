import CryptoKit
import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// Tests for `Reconciler`/`Walker`: gitignore-aware discovery (root and
/// nested), stats correctness, and the add/change/remove reconcile flows
/// against `Store`'s `indexed_files` table — port of `cleanup.rs`'s
/// `startup_cleanup` test suite.
struct ReconcilerTests {
    @Test
    func reconcileAddsNewFilesDirty() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("fn a() {}", to: "a.rs", in: root)
            try write("struct A {}", to: "b.swift", in: root)

            let stats = try await Reconciler.reconcile(store: store, rootDirectory: root)

            #expect(stats.walked == 2)
            #expect(stats.added == 2)
            #expect(stats.changed == 0)
            #expect(stats.removed == 0)

            let dirty = try await store.drainTsDirty()
            #expect(Set(dirty) == ["a.rs", "b.swift"])
        }
    }

    @Test
    func reconcileSecondPassOnUnchangedTreeIsNoOp() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("fn a() {}", to: "a.rs", in: root)

            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)
            let stats = try await Reconciler.reconcile(store: store, rootDirectory: root)

            #expect(stats.walked == 1)
            #expect(stats.added == 0)
            #expect(stats.changed == 0)
            #expect(stats.removed == 0)
        }
    }

    @Test
    func reconcileMarksChangedFileDirtyAndUpdatesHash() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("fn a() {}", to: "a.rs", in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)

            // Simulate a fully-indexed file so we can observe the dirty
            // flags flip from `true` back to `false`.
            try await store.markIndexed(filePath: "a.rs", layer: .treeSitter)
            try await store.markIndexed(filePath: "a.rs", layer: .lsp)
            try await store.markIndexed(filePath: "a.rs", layer: .embedding)
            #expect(try await store.drainTsDirty().isEmpty)

            try write("fn a_modified() {}", to: "a.rs", in: root)
            let stats = try await Reconciler.reconcile(store: store, rootDirectory: root)

            #expect(stats.changed == 1)
            #expect(stats.added == 0)
            #expect(stats.removed == 0)
            #expect(try await store.drainTsDirty() == ["a.rs"])
            #expect(try await store.drainLspDirty() == ["a.rs"])
            #expect(try await store.drainEmbeddingDirty() == ["a.rs"])

            let storedHash = try await store.read { db in
                try Data.fetchOne(db, sql: "SELECT content_hash FROM indexed_files WHERE file_path = 'a.rs'")
            }
            let expectedDigest = SHA256.hash(data: Data("fn a_modified() {}".utf8))
            #expect(storedHash == Data(expectedDigest.prefix(16)))
        }
    }

    @Test
    func reconcileDeletesRemovedFileAndCascades() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("fn a() {}", to: "a.rs", in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)

            try await store.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO ts_chunks (file_path, start_byte, end_byte, start_line, end_line, text, symbol_path, kind)
                    VALUES ('a.rs', 0, 10, 1, 1, 'fn a() {}', 'a', 'function')
                    """)
            }

            try FileManager.default.removeItem(at: root.appendingPathComponent("a.rs"))
            let stats = try await Reconciler.reconcile(store: store, rootDirectory: root)

            #expect(stats.removed == 1)
            #expect(stats.walked == 0)

            let remainingFiles = try await store.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM indexed_files") ?? 0
            }
            #expect(remainingFiles == 0)

            let remainingChunks = try await store.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ts_chunks") ?? 0
            }
            #expect(remainingChunks == 0)
        }
    }

    @Test
    func reconcileReportsCombinedStatsAcrossAddChangeRemoveUnchanged() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("fn a() {}", to: "a.rs", in: root)
            try write("fn b() {}", to: "b.rs", in: root)
            try write("fn c() {}", to: "c.rs", in: root)

            let firstStats = try await Reconciler.reconcile(store: store, rootDirectory: root)
            #expect(firstStats.added == 3)

            try FileManager.default.removeItem(at: root.appendingPathComponent("b.rs"))
            try write("fn c_modified() {}", to: "c.rs", in: root)

            let secondStats = try await Reconciler.reconcile(store: store, rootDirectory: root)
            #expect(secondStats.walked == 2)
            #expect(secondStats.removed == 1)
            #expect(secondStats.changed == 1)
            #expect(secondStats.added == 0)
        }
    }

    @Test
    func reconcileHonorsRootGitignore() async throws {
        try await withTemporaryWorkspace { root in
            try write("ignored.rs\n", to: ".gitignore", in: root)
            try write("fn ignored() {}", to: "ignored.rs", in: root)
            try write("fn kept() {}", to: "kept.rs", in: root)

            let store = try Store(rootDirectory: root)
            let stats = try await Reconciler.reconcile(store: store, rootDirectory: root)

            #expect(stats.walked == 1)
            #expect(stats.added == 1)

            let paths = try await store.drainTsDirty()
            #expect(paths == ["kept.rs"])
        }
    }

    @Test
    func reconcileHonorsNestedGitignoreScopedToItsDirectory() async throws {
        try await withTemporaryWorkspace { root in
            try write("fn top() {}", to: "top.rs", in: root)
            try write("*.rs\n", to: "vendor/.gitignore", in: root)
            try write("fn skipped() {}", to: "vendor/skipped.rs", in: root)
            try write("struct Keep {}", to: "vendor/keep.swift", in: root)

            let store = try Store(rootDirectory: root)
            let stats = try await Reconciler.reconcile(store: store, rootDirectory: root)

            let paths = Set(try await store.drainTsDirty())
            #expect(paths == ["top.rs", "vendor/keep.swift"])
            #expect(stats.walked == 2)
        }
    }

    @Test
    func reconcileHonorsGitignoreNegation() async throws {
        try await withTemporaryWorkspace { root in
            try write("*.rs\n!keep.rs\n", to: ".gitignore", in: root)
            try write("fn a() {}", to: "a.rs", in: root)
            try write("fn keep() {}", to: "keep.rs", in: root)

            let store = try Store(rootDirectory: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)

            let paths = try await store.drainTsDirty()
            #expect(paths == ["keep.rs"])
        }
    }

    @Test
    func reconcileHonorsDirectoryOnlyGitignorePattern() async throws {
        try await withTemporaryWorkspace { root in
            try write("build/\n", to: ".gitignore", in: root)
            try write("fn generated() {}", to: "build/gen.rs", in: root)
            try write("fn kept() {}", to: "kept.rs", in: root)

            let store = try Store(rootDirectory: root)
            let stats = try await Reconciler.reconcile(store: store, rootDirectory: root)

            #expect(stats.walked == 1)
            let paths = try await store.drainTsDirty()
            #expect(paths == ["kept.rs"])
        }
    }

    @Test
    func reconcileSkipsCodeContextDirectory() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("fn hidden() {}", to: ".code-context/leaked.rs", in: root)
            try write("fn visible() {}", to: "visible.rs", in: root)

            let stats = try await Reconciler.reconcile(store: store, rootDirectory: root)

            #expect(stats.walked == 1)
            #expect(stats.added == 1)
            let paths = try await store.drainTsDirty()
            #expect(paths == ["visible.rs"])
        }
    }
}

/// Tests for `Walker` directly: extension filtering and content hashing,
/// independent of `Reconciler`'s database reconciliation.
struct WalkerTests {
    @Test
    func walkHashesFileContentAsFirst16BytesOfSHA256() async throws {
        try await withTemporaryWorkspace { root in
            try write("fn a() {}", to: "a.rs", in: root)

            let files = try await Walker.walk(rootDirectory: root)
            #expect(files.count == 1)
            let file = try #require(files.first)
            #expect(file.relativePath == "a.rs")
            #expect(file.contentHash.count == 16)
            #expect(file.fileSize == Int64("fn a() {}".utf8.count))

            let expectedDigest = SHA256.hash(data: Data("fn a() {}".utf8))
            #expect(file.contentHash == Data(expectedDigest.prefix(16)))
        }
    }

    @Test
    func walkOnlyIncludesKnownLanguageExtensions() async throws {
        try await withTemporaryWorkspace { root in
            try write("fn a() {}", to: "a.rs", in: root)
            try write("not code", to: "notes.txt", in: root)

            let files = try await Walker.walk(rootDirectory: root)
            #expect(files.map(\.relativePath) == ["a.rs"])
        }
    }

    @Test
    func enumerateFilesRespectsExplicitExtensionFilter() async throws {
        try await withTemporaryWorkspace { root in
            try write("fn a() {}", to: "a.rs", in: root)
            try write("struct A {}", to: "b.swift", in: root)

            let rustOnly = try Walker.enumerateFiles(rootDirectory: root, extensions: ["rs"])
            #expect(rustOnly.map(\.lastPathComponent) == ["a.rs"])
        }
    }

    @Test
    func enumerateFilesMatchesExtensionsCaseInsensitively() async throws {
        try await withTemporaryWorkspace { root in
            try write("fn a() {}", to: "Sample.RS", in: root)
            try write("def a(): pass", to: "script.PY", in: root)

            let rustOnly = try Walker.enumerateFiles(rootDirectory: root, extensions: ["rs"])
            #expect(rustOnly.map(\.lastPathComponent) == ["Sample.RS"])

            let pythonOnly = try Walker.enumerateFiles(rootDirectory: root, extensions: ["py"])
            #expect(pythonOnly.map(\.lastPathComponent) == ["script.PY"])
        }
    }
}
