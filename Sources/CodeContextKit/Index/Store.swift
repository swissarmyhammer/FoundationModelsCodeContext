import Foundation
import GRDB

/// The per-file, per-layer indexing state tracked in `indexed_files`.
///
/// `markIndexed(filePath:layer:)` flips one of these flags to `true` when
/// its worker finishes a file; `markDirty(filePath:...)` resets all three
/// to `false` for a new or changed file.
public enum IndexLayer: Sendable, Hashable {
    /// The tree-sitter parse layer (`ts_indexed`).
    case treeSitter

    /// The LSP-derived symbol layer (`lsp_indexed`).
    case lsp

    /// The embedding layer (`embedded`).
    case embedding

    /// This layer's `indexed_files` dirty-flag column name, internal rather
    /// than `private`/`fileprivate` so `IndexAdmin` can reuse it instead of
    /// duplicating the layer-to-column mapping.
    ///
    /// A `switch`, not a `[IndexLayer: String]` dictionary: this mapping is
    /// closed (three cases, all colocated with this type) and never crosses
    /// a type or module boundary, so an exhaustive switch is the safer
    /// choice — the compiler rejects a missing arm at build time, whereas a
    /// dictionary lookup only fails at run time (via `!` force-unwrap, or
    /// silently via `??`/`Optional` if the `!` is later "fixed" away). This
    /// is the deliberate, final answer for every enum-to-related-value
    /// mapping in this file and `IndexAdmin` (`RebuildLayer.indexLayers`,
    /// `IndexAdmin.indexStatus`'s per-layer counting) — please don't
    /// re-litigate switch-vs-dictionary here again.
    var column: String {
        switch self {
        case .treeSitter:
            return Schema.IndexedFiles.tsIndexed
        case .lsp:
            return Schema.IndexedFiles.lspIndexed
        case .embedding:
            return Schema.IndexedFiles.embedded
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
    /// - Parameter rootDirectory: The workspace root to open or create the
    ///   store for.
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
    ///
    /// - Parameter block: The closure to execute against a read-only
    ///   connection.
    /// - Returns: The value returned by `block`.
    /// - Throws: Rethrows any error thrown by `block`, or
    ///   `CodeContextError.storage` if the database operation itself fails.
    public func read<T: Sendable>(_ block: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await withDbAccess(dbPool.read, block)
    }

    /// Runs `block` in a write transaction; see `read(_:)` for API details.
    ///
    /// - Parameter block: The closure to execute in a write transaction.
    /// - Returns: The value returned by `block`.
    /// - Throws: Rethrows any error thrown by `block`, or
    ///   `CodeContextError.storage` if the database operation itself fails.
    public func write<T: Sendable>(_ block: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await withDbAccess(dbPool.write, block)
    }

    /// Runs `block` via `dbPoolMethod` — `dbPool.read` or `dbPool.write`,
    /// which share this exact signature — translating any failure that
    /// isn't already a `CodeContextError` into `CodeContextError.storage`.
    ///
    /// Shared by `read(_:)` and `write(_:)`, which are otherwise identical
    /// and differ only in which `DatabasePool` method they hand off to.
    private func withDbAccess<T: Sendable>(
        _ dbPoolMethod: (@Sendable (Database) throws -> T) async throws -> T,
        _ block: @escaping @Sendable (Database) throws -> T
    ) async throws -> T {
        do {
            return try await dbPoolMethod(block)
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
    ///
    /// - Parameters:
    ///   - filePath: The file's workspace-relative path, the table's
    ///     primary key.
    ///   - contentHash: The file's current content hash, recorded for
    ///     change detection on the next reconcile.
    ///   - fileSize: The file's current size in bytes.
    ///   - lastSeenAt: When the file was last observed by the walker;
    ///     defaults to now.
    /// - Throws: `CodeContextError.storage` if the upsert fails.
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

    /// Deletes `filePath`'s `indexed_files` row, cascading to its chunks,
    /// symbols, and call edges via the table's foreign keys.
    ///
    /// This is the delete-time counterpart to
    /// `markDirty(filePath:contentHash:fileSize:lastSeenAt:)`: `Watcher`
    /// calls it for a live filesystem-delete event, so the same `DELETE`
    /// SQL isn't duplicated at each call site that needs to remove a file
    /// from the index.
    ///
    /// - Parameter filePath: The file's workspace-relative path to remove.
    /// - Throws: `CodeContextError.storage` if the delete fails.
    public func deleteFile(filePath: String) async throws {
        try await write { db in
            try db.execute(
                sql: "DELETE FROM \(Schema.IndexedFiles.table) WHERE \(Schema.IndexedFiles.filePath) = ?",
                arguments: [filePath]
            )
        }
    }

    /// File paths still awaiting tree-sitter indexing (`ts_indexed = 0`),
    /// for the tree-sitter worker to drain.
    ///
    /// - Returns: The dirty file paths, in path order.
    /// - Throws: `CodeContextError.storage` if the query fails.
    public func drainTsDirty() async throws -> [String] {
        try await drainDirty(column: IndexLayer.treeSitter.column)
    }

    /// File paths still awaiting LSP indexing (`lsp_indexed = 0`), for the
    /// LSP worker to drain.
    ///
    /// - Returns: The dirty file paths, in path order.
    /// - Throws: `CodeContextError.storage` if the query fails.
    public func drainLspDirty() async throws -> [String] {
        try await drainDirty(column: IndexLayer.lsp.column)
    }

    /// File paths still awaiting embedding (`embedded = 0`), for the
    /// embedding worker to drain.
    ///
    /// - Returns: The dirty file paths, in path order.
    /// - Throws: `CodeContextError.storage` if the query fails.
    public func drainEmbeddingDirty() async throws -> [String] {
        try await drainDirty(column: IndexLayer.embedding.column)
    }

    /// Runs the shared query behind `drainTsDirty()`, `drainLspDirty()`, and
    /// `drainEmbeddingDirty()`, which differ only in which dirty-flag
    /// `column` they check.
    ///
    /// - Parameter column: The `indexed_files` dirty-flag column to filter
    ///   on (`= 0`).
    /// - Returns: The dirty file paths, in path order.
    /// - Throws: `CodeContextError.storage` if the query fails.
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
    ///
    /// - Parameters:
    ///   - filePath: The file's workspace-relative path.
    ///   - layer: Which layer's flag to flip.
    /// - Throws: `CodeContextError.storage` if the update fails.
    public func markIndexed(filePath: String, layer: IndexLayer) async throws {
        try await write { db in
            try db.execute(
                sql: "UPDATE \(Schema.IndexedFiles.table) SET \(layer.column) = 1 WHERE \(Schema.IndexedFiles.filePath) = ?",
                arguments: [filePath]
            )
        }
    }

    /// Resets `layer`'s flag to dirty (`false`) for every currently tracked
    /// file, so the next `drainTsDirty()`/`drainLspDirty()`/
    /// `drainEmbeddingDirty()` call for that layer picks up the whole
    /// index.
    ///
    /// Unlike `markDirty(filePath:contentHash:fileSize:lastSeenAt:)` — which
    /// dirties all three layers for one specific file, as part of
    /// reconciling that file's changed content — this resets exactly one
    /// layer's column, across every file, without touching the other two
    /// layers or any file's `content_hash`/`file_size`. It is the bulk,
    /// admin-triggered counterpart `IndexAdmin.rebuildIndex` uses instead of
    /// duplicating layer-to-column knowledge outside `Store`.
    ///
    /// - Parameter layer: The layer to mark dirty for every file.
    /// - Returns: The number of files updated — every row in
    ///   `indexed_files`, since the `UPDATE` carries no `WHERE` clause.
    /// - Throws: `CodeContextError.storage` if the update fails.
    public func markAllDirty(layer: IndexLayer) async throws -> Int {
        try await write { db in
            try db.execute(sql: "UPDATE \(Schema.IndexedFiles.table) SET \(layer.column) = 0")
            return db.changesCount
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
    ///
    /// - Returns: The recorded dimension, or `nil` if none has been set.
    /// - Throws: `CodeContextError.storage` if the query fails.
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
    ///
    /// - Parameter dimension: The embedder dimension to record.
    /// - Throws: `CodeContextError.storage` if the upsert fails.
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
