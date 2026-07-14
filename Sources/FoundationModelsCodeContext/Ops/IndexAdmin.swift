import Foundation
import GRDB

/// Which indexing layer(s) `IndexAdmin.rebuildIndex(store:layer:)` resets.
///
/// Mirrors `Store.IndexLayer`'s three layers plus an `.all` case that resets
/// every layer at once — `Store.IndexLayer` has no such case since
/// `Store.markIndexed(filePath:layer:)`/`markAllDirty(layer:)` always act on
/// exactly one column at a time; `.all` exists only here, as a convenience
/// this op expands into the underlying per-layer calls.
public enum RebuildLayer: String, Codable, Sendable, Hashable, CaseIterable {
    /// Reset the tree-sitter layer (`ts_indexed`).
    case treeSitter = "treesitter"

    /// Reset the LSP layer (`lsp_indexed`).
    case lsp

    /// Reset the embedding layer (`embedded` — no `_indexed` suffix, unlike
    /// `ts_indexed`/`lsp_indexed`; see `Schema.IndexedFiles`).
    case embedding

    /// Reset every layer.
    case all

    /// The `Store.IndexLayer`(s) this rebuild layer resets.
    ///
    /// A `switch`, not a `[RebuildLayer: [IndexLayer]]` dictionary — see
    /// `IndexLayer.column`'s doc comment for the reasoning this codebase
    /// applies consistently: `RebuildLayer` is a closed enum colocated with
    /// this mapping, so an exhaustive switch turns a missing case into a
    /// compile error, instead of `rebuildIndex(store:layer:)` silently
    /// no-oping (an empty array from a missing dictionary key) the moment a
    /// new `RebuildLayer` case is added.
    var indexLayers: [IndexLayer] {
        switch self {
        case .treeSitter:
            return [.treeSitter]
        case .lsp:
            return [.lsp]
        case .embedding:
            return [.embedding]
        case .all:
            return [.treeSitter, .lsp, .embedding]
        }
    }
}

/// The result of an `IndexAdmin.rebuildIndex(store:layer:)` call.
public struct RebuildIndexResult: Codable, Sendable, Equatable {
    /// Which layer(s) were reset.
    public let layer: RebuildLayer

    /// The number of files marked dirty — every row in `indexed_files`,
    /// since the underlying `UPDATE` carries no `WHERE` clause.
    public let filesMarked: Int

    /// Creates a rebuild-index result.
    ///
    /// - Parameters:
    ///   - layer: Which layer(s) were reset.
    ///   - filesMarked: The number of files marked dirty.
    public init(layer: RebuildLayer, filesMarked: Int) {
        self.layer = layer
        self.filesMarked = filesMarked
    }
}

/// A health report for a workspace's index, counting files and percentages
/// per layer from `indexed_files`.
public struct IndexStatus: Codable, Sendable, Equatable {
    /// The total number of tracked files.
    public let totalFiles: Int

    /// The number of files with `ts_indexed = 1`.
    public let treeSitterIndexedFiles: Int

    /// The tree-sitter indexed percentage, `0.0` to `100.0`.
    public let treeSitterIndexedPercent: Double

    /// The number of files with `lsp_indexed = 1`.
    public let lspIndexedFiles: Int

    /// The LSP indexed percentage, `0.0` to `100.0`.
    public let lspIndexedPercent: Double

    /// The number of files with `embedded = 1` (no `_indexed` suffix on this
    /// column, unlike `ts_indexed`/`lsp_indexed`; see `Schema.IndexedFiles`).
    public let embeddedIndexedFiles: Int

    /// The embedded indexed percentage, `0.0` to `100.0`.
    public let embeddedIndexedPercent: Double

    /// Creates an index status report.
    ///
    /// - Parameters:
    ///   - totalFiles: The total number of tracked files.
    ///   - treeSitterIndexedFiles: The number of tree-sitter-indexed files.
    ///   - treeSitterIndexedPercent: The tree-sitter indexed percentage.
    ///   - lspIndexedFiles: The number of LSP-indexed files.
    ///   - lspIndexedPercent: The LSP indexed percentage.
    ///   - embeddedIndexedFiles: The number of embedded-indexed files.
    ///   - embeddedIndexedPercent: The embedded indexed percentage.
    public init(
        totalFiles: Int,
        treeSitterIndexedFiles: Int,
        treeSitterIndexedPercent: Double,
        lspIndexedFiles: Int,
        lspIndexedPercent: Double,
        embeddedIndexedFiles: Int,
        embeddedIndexedPercent: Double
    ) {
        self.totalFiles = totalFiles
        self.treeSitterIndexedFiles = treeSitterIndexedFiles
        self.treeSitterIndexedPercent = treeSitterIndexedPercent
        self.lspIndexedFiles = lspIndexedFiles
        self.lspIndexedPercent = lspIndexedPercent
        self.embeddedIndexedFiles = embeddedIndexedFiles
        self.embeddedIndexedPercent = embeddedIndexedPercent
    }
}

/// Index health reporting (`indexStatus`) and admin-triggered re-indexing
/// (`rebuildIndex`) over a workspace's `indexed_files` table.
///
/// Port of the Rust `swissarmyhammer-code-context::ops::status` module's
/// `get_status`/`rebuild_index` functions
/// (`crates/swissarmyhammer-code-context/src/ops/status.rs`), scoped to the
/// `indexed_files`-derived counts the task calls for (files, per-layer
/// indexed counts/percentages) — the Rust reference's additional
/// `ts_chunks`/`lsp_symbols`/`lsp_call_edges` counts and `clear_status`
/// aren't part of this port.
///
/// `rebuildIndex` only flips dirty bits (via `Store.markAllDirty(layer:)`);
/// it does not drive a worker drain itself. Callers that need the rebuilt
/// layer's data back re-run the appropriate worker (`TreeSitterWorker.run`,
/// the LSP/embedding workers) afterward — matching the Rust reference's own
/// "marks files for re-indexing... does not run the indexer itself"
/// contract.
public enum IndexAdmin {
    /// Reports per-layer file counts and percentages from `indexed_files`.
    ///
    /// - Parameter store: The workspace's index store to report on.
    /// - Returns: Total files tracked, plus each layer's indexed count and
    ///   percentage (`0.0` when there are no tracked files).
    /// - Throws: Rethrows `Store`'s storage errors.
    public static func indexStatus(store: Store) async throws -> IndexStatus {
        try await store.read { db in
            let totalFiles = try count(db: db, whereClause: "")

            // Three direct calls, not a loop over `IndexLayer.allCases`
            // collected into a `[IndexLayer: Int]` dictionary: `IndexStatus`
            // has one hardcoded field per layer (mirroring the Rust
            // reference's status shape), so a loop that counts every case
            // would keep computing a future layer's count while this
            // function still only reads back the three keys it knows about
            // — the extra count would be silently dropped when building
            // `IndexStatus`, with nothing here to catch it. Each call still
            // routes through `countIndexed(db:layer:)`, so the per-layer
            // `WHERE` clause is written once; only the three known counts
            // this struct actually has fields for are computed.
            let treeSitterIndexedFiles = try countIndexed(db: db, layer: .treeSitter)
            let lspIndexedFiles = try countIndexed(db: db, layer: .lsp)
            let embeddedIndexedFiles = try countIndexed(db: db, layer: .embedding)

            return IndexStatus(
                totalFiles: totalFiles,
                treeSitterIndexedFiles: treeSitterIndexedFiles,
                treeSitterIndexedPercent: percent(numerator: treeSitterIndexedFiles, denominator: totalFiles),
                lspIndexedFiles: lspIndexedFiles,
                lspIndexedPercent: percent(numerator: lspIndexedFiles, denominator: totalFiles),
                embeddedIndexedFiles: embeddedIndexedFiles,
                embeddedIndexedPercent: percent(numerator: embeddedIndexedFiles, denominator: totalFiles)
            )
        }
    }

    /// Marks every currently tracked file dirty for `layer`, so the next
    /// drain/re-indexing pass for that layer reprocesses the whole index.
    ///
    /// Does not run any worker itself — see this enum's doc comment.
    ///
    /// - Parameters:
    ///   - store: The workspace's index store to mark dirty.
    ///   - layer: Which layer(s) to reset. `.all` resets tree-sitter, LSP,
    ///     and embedding together.
    /// - Returns: Which layer was reset, and how many files were marked
    ///   dirty.
    /// - Throws: Rethrows `Store`'s storage errors.
    @discardableResult
    public static func rebuildIndex(store: Store, layer: RebuildLayer) async throws -> RebuildIndexResult {
        var filesMarked = 0
        for storeLayer in layer.indexLayers {
            // Every call's changesCount is the same total row count (the
            // underlying UPDATE carries no WHERE clause, so it always
            // touches every row) regardless of which column it resets;
            // keeping the last one avoids triple-counting for `.all`.
            filesMarked = try await store.markAllDirty(layer: storeLayer)
        }
        return RebuildIndexResult(layer: layer, filesMarked: filesMarked)
    }

    /// Runs `SELECT COUNT(*) FROM indexed_files <whereClause>` and returns
    /// the count.
    private static func count(db: Database, whereClause: String) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(Schema.IndexedFiles.table) \(whereClause)") ?? 0
    }

    /// Counts the files with `layer`'s `indexed_files` flag set to `1`.
    ///
    /// Shared by `indexStatus()`'s three per-layer counts, which otherwise
    /// differ only in which `IndexLayer` they pass.
    ///
    /// - Parameters:
    ///   - db: The database connection to query.
    ///   - layer: Which layer's indexed flag to count.
    /// - Returns: The number of files with `layer`'s column set to `1`.
    /// - Throws: Rethrows any error the underlying query throws.
    private static func countIndexed(db: Database, layer: IndexLayer) throws -> Int {
        try count(db: db, whereClause: "WHERE \(layer.column) = 1")
    }

    /// Computes `(numerator / denominator) * 100.0`, returning `0.0` when
    /// `denominator` is zero.
    private static func percent(numerator: Int, denominator: Int) -> Double {
        guard denominator > 0 else {
            return 0.0
        }
        return Double(numerator) / Double(denominator) * 100.0
    }
}
