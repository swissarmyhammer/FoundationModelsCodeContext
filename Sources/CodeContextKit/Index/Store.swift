import Foundation
import GRDB

/// The per-file, per-layer indexing state tracked in `indexed_files`.
///
/// `markIndexed(filePath:layer:)` flips one of these flags to `true` when
/// its worker finishes a file; `markDirty(filePath:...)` resets all three
/// to `false` for a new or changed file.
public enum IndexLayer: Sendable {
    case treeSitter
    case lsp
    case embedding

    var column: String {
        switch self {
        case .treeSitter: Schema.IndexedFiles.tsIndexed
        case .lsp: Schema.IndexedFiles.lspIndexed
        case .embedding: Schema.IndexedFiles.embedded
        }
    }
}

/// GRDB-backed SQLite store for one workspace's `.code-context/kit.db`.
///
/// Owns the `DatabasePool`, runs schema migrations on open, and exposes the
/// per-layer dirty-flag bookkeeping (`indexed_files.ts_indexed/lsp_indexed/
/// embedded`) that the tree-sitter, LSP, and embedding workers drain. See
/// plan.md "The index (SQLite, Rust-derived schema — owned by us)".
///
/// `DatabasePool` is itself a thread-safe GRDB type (concurrent readers,
/// one serialized writer), so `Store` needs no additional actor isolation
/// — it is a plain `Sendable` reference type, safe to share across the
/// workers that `CodeContext` owns.
public final class Store: Sendable {
    /// Workspace root this store was opened for.
    public let rootDirectory: URL

    /// `<rootDirectory>/.code-context`.
    public let indexDirectory: URL

    /// `<rootDirectory>/.code-context/kit.db`.
    public let databaseURL: URL

    private let dbPool: DatabasePool

    /// Opens (creating if necessary) the store for `rootDirectory`.
    ///
    /// Bootstraps `.code-context/` with a self-`.gitignore` (`*`, so the
    /// index directory never needs an entry in the workspace's own
    /// `.gitignore`), opens a GRDB `DatabasePool` at `kit.db` — WAL mode,
    /// which `DatabasePool` configures automatically — and runs all
    /// migrations synchronously, so the store is fully ready to use as
    /// soon as `init` returns.
    ///
    /// - Throws: `CodeContextError.storage` if the directory can't be
    ///   created, the database can't be opened, or migrations fail.
    public init(rootDirectory: URL) throws {
        self.rootDirectory = rootDirectory
        indexDirectory = rootDirectory.appendingPathComponent(".code-context", isDirectory: true)
        databaseURL = indexDirectory.appendingPathComponent("kit.db", isDirectory: false)

        do {
            try Self.bootstrapIndexDirectory(at: indexDirectory)
        } catch {
            throw CodeContextError.storage("failed to bootstrap \(indexDirectory.path): \(error.localizedDescription)")
        }

        let pool: DatabasePool
        do {
            pool = try DatabasePool(path: databaseURL.path)
        } catch {
            throw CodeContextError.storage("failed to open \(databaseURL.path): \(error.localizedDescription)")
        }

        do {
            try Migrations.migrator.migrate(pool)
        } catch {
            throw CodeContextError.storage("migration failed for \(databaseURL.path): \(error.localizedDescription)")
        }

        dbPool = pool
    }

    /// Creates `.code-context/` if missing and (re)writes its
    /// self-`.gitignore` (`*`) so the index directory is never committed,
    /// independent of the enclosing repo's own ignore rules.
    private static func bootstrapIndexDirectory(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let gitignoreURL = directory.appendingPathComponent(".gitignore", isDirectory: false)
        try "*\n".write(to: gitignoreURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Generic access

    /// Runs `block` against a read-only connection from the pool.
    ///
    /// Exposed as an escape hatch for subsystems (walker, tree-sitter/LSP
    /// workers, search) that need direct query access to tables this type
    /// doesn't otherwise wrap, beyond the dirty-flag helpers below.
    public func read<T: Sendable>(_ block: @escaping @Sendable (Database) throws -> T) async throws -> T {
        do {
            return try await dbPool.read(block)
        } catch let error as CodeContextError {
            throw error
        } catch {
            throw CodeContextError.storage(error.localizedDescription)
        }
    }

    /// Runs `block` in a write transaction. See `read(_:)`.
    public func write<T: Sendable>(_ block: @escaping @Sendable (Database) throws -> T) async throws -> T {
        do {
            return try await dbPool.write(block)
        } catch let error as CodeContextError {
            throw error
        } catch {
            throw CodeContextError.storage(error.localizedDescription)
        }
    }

    // MARK: - Dirty-flag lifecycle (indexed_files)

    /// Upserts `filePath`'s `indexed_files` row and resets all three
    /// per-layer flags (`ts_indexed`, `lsp_indexed`, `embedded`) to dirty
    /// (`false`).
    ///
    /// This is the reconcile-time action for both new and changed files
    /// (port of `startup_cleanup`'s "changed → mark all layers dirty, new
    /// → INSERT dirty"); deleted files instead get their row `DELETE`d,
    /// which cascades to their chunks/symbols/edges.
    public func markDirty(
        filePath: String,
        contentHash: Data,
        fileSize: Int64,
        lastSeenAt: Date = Date()
    ) async throws {
        try await write { db in
            try db.execute(
                sql: """
                INSERT INTO \(Schema.IndexedFiles.table)
                    (\(Schema.IndexedFiles.filePath), \(Schema.IndexedFiles.contentHash), \
                     \(Schema.IndexedFiles.fileSize), \(Schema.IndexedFiles.lastSeenAt), \
                     \(Schema.IndexedFiles.tsIndexed), \(Schema.IndexedFiles.lspIndexed), \(Schema.IndexedFiles.embedded))
                VALUES (?, ?, ?, ?, 0, 0, 0)
                ON CONFLICT(\(Schema.IndexedFiles.filePath)) DO UPDATE SET
                    \(Schema.IndexedFiles.contentHash) = excluded.\(Schema.IndexedFiles.contentHash),
                    \(Schema.IndexedFiles.fileSize) = excluded.\(Schema.IndexedFiles.fileSize),
                    \(Schema.IndexedFiles.lastSeenAt) = excluded.\(Schema.IndexedFiles.lastSeenAt),
                    \(Schema.IndexedFiles.tsIndexed) = 0,
                    \(Schema.IndexedFiles.lspIndexed) = 0,
                    \(Schema.IndexedFiles.embedded) = 0
                """,
                arguments: [filePath, contentHash, fileSize, lastSeenAt]
            )
        }
    }

    /// File paths still awaiting tree-sitter indexing (`ts_indexed = 0`),
    /// for the tree-sitter worker to drain.
    public func drainTsDirty() async throws -> [String] {
        try await drainDirty(column: Schema.IndexedFiles.tsIndexed)
    }

    /// File paths still awaiting LSP indexing (`lsp_indexed = 0`), for the
    /// LSP worker to drain.
    public func drainLspDirty() async throws -> [String] {
        try await drainDirty(column: Schema.IndexedFiles.lspIndexed)
    }

    private func drainDirty(column: String) async throws -> [String] {
        try await read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT \(Schema.IndexedFiles.filePath) FROM \(Schema.IndexedFiles.table) \
                WHERE \(column) = 0 ORDER BY \(Schema.IndexedFiles.filePath)
                """
            )
        }
    }

    /// Marks `filePath` as done for `layer`, flipping its flag to `true`.
    public func markIndexed(filePath: String, layer: IndexLayer) async throws {
        try await write { db in
            try db.execute(
                sql: "UPDATE \(Schema.IndexedFiles.table) SET \(layer.column) = 1 WHERE \(Schema.IndexedFiles.filePath) = ?",
                arguments: [filePath]
            )
        }
    }

    // MARK: - meta (embedder dimension)

    private static let embedderDimensionKey = "embedder_dimension"

    /// The embedder dimension recorded the last time chunks were embedded,
    /// or `nil` if none has been recorded yet.
    ///
    /// Callers compare this against the current embedder's `dimension`; a
    /// mismatch means every chunk must be treated as un-embedded and
    /// re-embedded (see plan.md "Embeddings").
    public func embedderDimension() async throws -> Int? {
        try await read { db in
            try String.fetchOne(
                db,
                sql: "SELECT \(Schema.Meta.value) FROM \(Schema.Meta.table) WHERE \(Schema.Meta.key) = ?",
                arguments: [Self.embedderDimensionKey]
            ).flatMap(Int.init)
        }
    }

    /// Records the embedder dimension currently in use.
    public func setEmbedderDimension(_ dimension: Int) async throws {
        try await write { db in
            try db.execute(
                sql: """
                INSERT INTO \(Schema.Meta.table) (\(Schema.Meta.key), \(Schema.Meta.value)) VALUES (?, ?)
                ON CONFLICT(\(Schema.Meta.key)) DO UPDATE SET \(Schema.Meta.value) = excluded.\(Schema.Meta.value)
                """,
                arguments: [Self.embedderDimensionKey, String(dimension)]
            )
        }
    }
}
