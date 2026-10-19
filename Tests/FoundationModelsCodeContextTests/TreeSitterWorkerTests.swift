import Foundation
import GRDB
import InMemoryLogging
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
        try await TemporaryItem.withNestedWorkspace { root in
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

    // MARK: - Files that the read does not give as text

    /// The text of a file whose functions call each other, thus the pass
    /// writes chunks, symbols and call edges for it.
    private static let callingSource = "func caller() { callee() }\nfunc callee() {}\n"

    /// Bytes that are not UTF-8 text.
    private static let notUTF8 = Data([0xFF, 0xFE, 0xFD])

    /// The tables that hold the rows of one indexed file.
    private static let fileTables = [
        Schema.IndexedFiles.table, Schema.TsChunks.table, Schema.LspSymbols.table, Schema.LspCallEdges.table,
    ]

    /// Counts the rows of `filePath` in each table of `fileTables`.
    /// - Parameters:
    ///   - filePath: The workspace-relative path of the file.
    ///   - store: The index store to read.
    /// - Returns: The row count of each table, keyed by the table name.
    private static func rowCounts(ofFilePath filePath: String, store: Store) async throws -> [String: Int] {
        try await store.read { db in
            try Dictionary(
                uniqueKeysWithValues: fileTables.map { table in
                    (table, try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE file_path = ?", arguments: [filePath]) ?? 0)
                }
            )
        }
    }

    /// Gives the captured log records of `filePath`.
    /// - Parameter filePath: The workspace-relative path of the file.
    /// - Returns: The records whose file path metadata is `filePath`.
    private static func logRecords(ofFilePath filePath: String) -> [InMemoryLogHandler.Entry] {
        CapturedLogRecords.entries(matching: [CodeContextTracing.MetadataKey.filePath: filePath])
    }

    @Test
    func runRemovesTheRowsOfAFileDeletedBeforeTheReadAndWritesNoWarning() async throws {
        _ = CapturedLogRecords.handler
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            let filePath = "Deleted-\(UUID().uuidString).swift"
            try write(Self.callingSource, to: filePath, in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)
            try await TreeSitterWorker.run(store: store, rootDirectory: root)
            let indexedCounts = try await Self.rowCounts(ofFilePath: filePath, store: store)
            try #require(indexedCounts.values.allSatisfy { $0 > 0 }, "the test needs a file with rows in each table: \(indexedCounts)")

            try await store.markDirty(filePath: filePath, contentHash: Data(filePath.utf8), fileSize: 1)
            try FileManager.default.removeItem(at: root.appendingPathComponent(filePath))
            let processed = try await TreeSitterWorker.run(store: store, rootDirectory: root)

            #expect(processed == 1)
            let remainingCounts = try await Self.rowCounts(ofFilePath: filePath, store: store)
            #expect(remainingCounts.values.allSatisfy { $0 == 0 }, "\(remainingCounts)")
            let records = Self.logRecords(ofFilePath: filePath)
            #expect(!records.isEmpty, "the pass writes a record for the deleted file")
            #expect(records.allSatisfy { $0.level == .debug })
        }
    }

    @Test
    func runWritesTheNotUTF8MessageForAFileThatIsNotUTF8Text() async throws {
        _ = CapturedLogRecords.handler
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            let filePath = "NotUTF8-\(UUID().uuidString).swift"
            try Self.notUTF8.write(to: root.appendingPathComponent(filePath))
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)

            try await TreeSitterWorker.run(store: store, rootDirectory: root)

            #expect(try await store.drainTsDirty().isEmpty)
            let records = Self.logRecords(ofFilePath: filePath)
            #expect(
                records.map(\.message.description)
                    == ["the tree-sitter index worker skips a file that is not UTF-8 text and marks the file indexed"]
            )
            #expect(records.allSatisfy { $0.level == .info })
        }
    }

    @Test
    func runKeepsTheWarningWithTheErrorTypeForAFileThatCannotBeRead() async throws {
        _ = CapturedLogRecords.handler
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            let filePath = "Unreadable-\(UUID().uuidString).swift"
            try write(Self.callingSource, to: filePath, in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)

            _ = try await withPermissions(noAccessPermissions, at: root.appendingPathComponent(filePath), restoringTo: restoredFilePermissions) {
                try await TreeSitterWorker.run(store: store, rootDirectory: root)
            }

            #expect(try await store.drainTsDirty().isEmpty)
            #expect(try await Self.rowCounts(ofFilePath: filePath, store: store)[Schema.IndexedFiles.table] == 1)
            let records = Self.logRecords(ofFilePath: filePath)
            #expect(records.map(\.message.description) == ["the tree-sitter index worker cannot read the file"])
            #expect(records.allSatisfy { $0.level == .warning })
            #expect(records.allSatisfy { $0.metadata[CodeContextTracing.MetadataKey.errorType] != nil })
        }
    }
}
