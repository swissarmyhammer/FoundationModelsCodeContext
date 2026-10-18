import Foundation
import GRDB

/// Statistics from one `Reconciler.reconcile(store:rootDirectory:)` pass.
///
/// Port of `cleanup.rs`'s `CleanupStats`.
public struct CleanupStats: Sendable, Equatable {
    /// Total number of non-ignored, indexable files found on disk.
    public let walked: Int

    /// Files on disk that were not yet in `indexed_files` and have been
    /// inserted dirty.
    public let added: Int

    /// Files whose content hash differs from the stored one and have been
    /// marked dirty.
    public let changed: Int

    /// Files that were in `indexed_files` but no longer exist on disk, and
    /// have been deleted (cascading to their chunks/symbols/edges).
    public let removed: Int

    /// Entries that the walk could not examine: a directory that it could not
    /// list, an entry whose type it could not read, and a file that it could
    /// not read. The reconcile keeps each row at or below these paths.
    public let skipped: Int
}

/// Reconciles a workspace's `indexed_files` table against the files
/// actually on disk.
///
/// Port of `cleanup.rs::startup_cleanup`: walks and hashes the workspace
/// with `Walker`, then for every difference between disk and the database:
/// - on disk but not in the database → `Store.markDirty` (insert, dirty)
/// - in the database with a changed hash → `Store.markDirty` (update,
///   dirty)
/// - in the database but no longer on disk, or now ignored by `PathFilter`
///   → `DELETE`, cascading to chunks/symbols/edges via the existing foreign
///   keys
///
/// The reconcile does not delete a row at or below a path that the walk could
/// not examine (for example a directory with a temporary permission error):
/// the walk does not know if those files are on disk.
///
/// Intended to run once at startup (leader only) before the indexing
/// workers begin, and safe to re-run at any time — an unchanged tree
/// produces `added`/`changed`/`removed` all zero.
public enum Reconciler {
    /// Walks `rootDirectory` and reconciles it against `store`'s
    /// `indexed_files` table.
    ///
    /// - Parameters:
    ///   - store: The workspace's index store to reconcile against.
    ///   - rootDirectory: The workspace root to walk; should match the
    ///     directory `store` was opened for, so relative paths line up
    ///     with `indexed_files.file_path`.
    /// - Returns: Counts of files walked, added, changed, removed, and of the
    ///   entries that the walk skipped.
    /// - Throws: Rethrows `Walker.walk`'s filesystem errors (the walk throws
    ///   only when it cannot list the root), or `CodeContextError.storage`
    ///   from `store`'s database operations.
    public static func reconcile(store: Store, rootDirectory: URL) async throws -> CleanupStats {
        try await reconcile(store: store, rootDirectory: rootDirectory, readEntryType: Walker.entryType(at:))
    }

    /// Walks `rootDirectory` with `readEntryType` and reconciles it against
    /// `store`'s `indexed_files` table.
    ///
    /// The public `reconcile(store:rootDirectory:)` calls this function with
    /// `Walker.entryType(at:)`. A test gives a reader that fails for one
    /// entry, to make an entry whose type the walk cannot read.
    /// - Parameters:
    ///   - store: The workspace's index store to reconcile against.
    ///   - rootDirectory: The workspace root to walk.
    ///   - readEntryType: Reads the type of each entry of the walk.
    /// - Returns: Counts of files walked, added, changed, removed, and of the
    ///   entries that the walk skipped.
    /// - Throws: The errors of `reconcile(store:rootDirectory:)`.
    static func reconcile(
        store: Store,
        rootDirectory: URL,
        readEntryType: @escaping Walker.EntryTypeReader
    ) async throws -> CleanupStats {
        let walk = try await Walker.walk(rootDirectory: rootDirectory, readEntryType: readEntryType)
        let diskFiles = walk.files
        let diskByPath = Dictionary(uniqueKeysWithValues: diskFiles.map { ($0.relativePath, $0) })

        let existingHashes = try await loadExistingHashes(store: store)

        let removedPaths = Array(existingHashes.keys.filter { diskByPath[$0] == nil && !walk.isUnexamined($0) })
        try await deleteRows(filePaths: removedPaths, store: store)

        var addedCount = 0
        var changedCount = 0
        for diskFile in diskFiles {
            let storedHash = existingHashes[diskFile.relativePath]
            guard storedHash == nil || storedHash != diskFile.contentHash else {
                continue
            }
            try await store.markDirty(
                filePath: diskFile.relativePath,
                contentHash: diskFile.contentHash,
                fileSize: diskFile.fileSize
            )
            if storedHash == nil {
                addedCount += 1
            } else {
                changedCount += 1
            }
        }

        return CleanupStats(
            walked: diskFiles.count,
            added: addedCount,
            changed: changedCount,
            removed: removedPaths.count,
            skipped: walk.unexaminedPaths.count
        )
    }

    /// Loads every `indexed_files.file_path` → `content_hash` pair
    /// currently stored, for comparison against the disk walk.
    private static func loadExistingHashes(store: Store) async throws -> [String: Data] {
        try await store.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT \(Schema.IndexedFiles.filePath), \(Schema.IndexedFiles.contentHash) FROM \(Schema.IndexedFiles.table)"
            )
            var hashes: [String: Data] = [:]
            for row in rows {
                let path: String = row[Schema.IndexedFiles.filePath]
                let hash: Data = row[Schema.IndexedFiles.contentHash]
                hashes[path] = hash
            }
            return hashes
        }
    }

    /// Deletes `indexed_files` rows for `filePaths`, cascading to their
    /// chunks/symbols/edges.
    private static func deleteRows(filePaths: [String], store: Store) async throws {
        guard !filePaths.isEmpty else {
            return
        }
        try await store.write { db in
            for filePath in filePaths {
                try db.execute(
                    sql: "DELETE FROM \(Schema.IndexedFiles.table) WHERE \(Schema.IndexedFiles.filePath) = ?",
                    arguments: [filePath]
                )
            }
        }
    }
}
