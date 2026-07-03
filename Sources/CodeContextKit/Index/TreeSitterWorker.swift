import Foundation
import GRDB

/// Drains `ts_indexed = 0` files from a `Store`, parses and chunks each via
/// `Chunker`, and writes the resulting `SemanticChunk`s into `ts_chunks`.
///
/// Port of the tree-sitter portion of the Rust
/// `index_discovered_files_with_embedder`
/// (`swissarmyhammer-tools/src/mcp/tools/code_context/mod.rs`): chunk
/// extraction and storage, plus an optional embedding step. Parsing (via
/// `Chunker.chunk(file:module:)`) always runs outside any database
/// transaction; only the `DELETE`+`INSERT` for a file's chunks and its
/// `ts_indexed` flag flip happen inside one `Store.write` block.
///
/// When `run(store:rootDirectory:embedder:)` is given an `embedder`, it also
/// drains `embedded = 0` files — every file just (re)chunked above, plus any
/// file left over from a prior pass that had no embedder or whose embedder
/// failed — and batch-embeds each file's chunk texts, storing vectors via
/// `EmbeddingCodec`. Without an `embedder`, every written row's `embedding`
/// column stays `NULL`, exactly as before this integration.
public enum TreeSitterWorker {
    /// Drains and processes every file with `ts_indexed = 0` in `store`, then
    /// — if `embedder` is given — embeds every file with `embedded = 0`.
    ///
    /// For each dirty file: reads its content from disk (relative to
    /// `rootDirectory`), looks up its `LanguageModule` by extension, chunks
    /// it, replaces its `ts_chunks` rows, and marks it indexed. A file is
    /// always marked indexed, so it isn't retried forever, but the two ways
    /// chunking can come up empty are handled differently: a file whose
    /// language module can't be resolved or can't be read as UTF-8 text
    /// skips the `ts_chunks` write entirely, leaving any existing rows from
    /// a prior successful pass untouched; a file that resolves and reads but
    /// fails to parse (or genuinely has no chunkable nodes) still runs the
    /// write, which — per `Chunker.chunk(file:module:)`'s empty-array
    /// contract for both cases — replaces its rows with none.
    ///
    /// The embedding step, when `embedder` is given, runs independently of
    /// how many files were chunked this pass (see `embedDirtyChunks`).
    ///
    /// - Parameters:
    ///   - store: The workspace's index store to drain and write into.
    ///   - rootDirectory: The workspace root dirty file paths are relative
    ///     to.
    ///   - embedder: The embedder to use for the embedding step, or `nil` to
    ///     skip embedding entirely, leaving chunks with a `NULL` embedding.
    ///     Defaults to `nil`.
    /// - Returns: The number of dirty tree-sitter files drained this pass.
    /// - Throws: Rethrows `Store`'s storage errors.
    @discardableResult
    public static func run(store: Store, rootDirectory: URL, embedder: TextEmbedding? = nil) async throws -> Int {
        let dirtyPaths = try await store.drainTsDirty()

        for relativePath in dirtyPaths {
            if let chunks = readAndChunk(relativePath: relativePath, rootDirectory: rootDirectory) {
                try await writeChunks(chunks: chunks, filePath: relativePath, store: store)
            }
            try await store.markIndexed(filePath: relativePath, layer: .treeSitter)
        }

        if let embedder {
            try await embedDirtyChunks(embedder: embedder, store: store)
        }

        return dirtyPaths.count
    }

    /// Reads `relativePath`'s content from disk and chunks it with its
    /// registered `LanguageModule`, or `nil` if the language module can't be
    /// resolved or the file can't be read as UTF-8 text.
    ///
    /// Runs entirely outside any database transaction.
    private static func readAndChunk(relativePath: String, rootDirectory: URL) -> [SemanticChunk]? {
        let fileExtension = URL(fileURLWithPath: relativePath).pathExtension
        guard let module = Languages.module(forFileExtension: fileExtension) else {
            Log.index.warning("no language module for \(relativePath, privacy: .public)")
            return nil
        }

        let fileURL = rootDirectory.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: fileURL), let contents = String(data: data, encoding: .utf8) else {
            Log.index.warning("failed to read \(relativePath, privacy: .public)")
            return nil
        }

        let file = SourceFile(relativePath: relativePath, contents: contents)
        return Chunker.chunk(file: file, module: module)
    }

    /// Replaces `filePath`'s `ts_chunks` rows with `chunks`, in one write
    /// transaction: deletes the file's existing rows (so a re-chunked,
    /// changed file doesn't accumulate stale rows alongside the new ones),
    /// then inserts each chunk with a `NULL` embedding.
    private static func writeChunks(chunks: [SemanticChunk], filePath: String, store: Store) async throws {
        try await store.write { db in
            try db.execute(
                sql: "DELETE FROM \(Schema.TsChunks.table) WHERE \(Schema.TsChunks.filePath) = ?",
                arguments: [filePath]
            )
            for chunk in chunks {
                try db.execute(
                    sql: """
                    INSERT INTO \(Schema.TsChunks.table)
                        (\(Schema.TsChunks.filePath), \(Schema.TsChunks.startByte), \(Schema.TsChunks.endByte), \
                         \(Schema.TsChunks.startLine), \(Schema.TsChunks.endLine), \(Schema.TsChunks.text), \
                         \(Schema.TsChunks.symbolPath), \(Schema.TsChunks.kind))
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        chunk.filePath, chunk.startByte, chunk.endByte,
                        chunk.startLine, chunk.endLine, chunk.text,
                        chunk.symbolPath, chunk.kind.rawValue,
                    ]
                )
            }
        }
    }

    // MARK: - Embedding

    /// Batch-embeds every chunk of every file with `embedded = 0`, writing
    /// vectors through `EmbeddingCodec` and marking each file's `embedded`
    /// flag once its whole batch succeeds.
    ///
    /// Before draining, reconciles `embedder`'s dimension against the one
    /// recorded in `meta` the last time embedding ran (see
    /// `reconcileEmbedderDimension`): a mismatch clears every chunk's
    /// embedding and every file's `embedded` flag, so the drain below picks
    /// up the whole index for full re-embedding instead of leaving stale,
    /// wrong-dimension vectors in place. This runs regardless of how many
    /// files the tree-sitter pass just chunked — including a pass with zero
    /// dirty files, which is how a dimension change alone (no source
    /// changes) still triggers a full re-embed.
    private static func embedDirtyChunks(embedder: TextEmbedding, store: Store) async throws {
        try await reconcileEmbedderDimension(embedder: embedder, store: store)

        let dirtyPaths = try await store.drainEmbeddingDirty()
        for filePath in dirtyPaths {
            try await embedChunks(forFilePath: filePath, embedder: embedder, store: store)
        }
    }

    /// Compares `embedder.dimension` against the dimension stored in `meta`
    /// and, on a mismatch, clears every chunk's embedding and resets every
    /// file's `embedded` flag so the next drain fully re-embeds the index.
    ///
    /// No stored dimension (a fresh index, or one that has never embedded)
    /// is not a mismatch — it just records the current dimension.
    private static func reconcileEmbedderDimension(embedder: TextEmbedding, store: Store) async throws {
        let storedDimension = try await store.embedderDimension()
        if let storedDimension, storedDimension != embedder.dimension {
            Log.embedding.notice(
                "embedder dimension changed \(storedDimension) -> \(embedder.dimension, privacy: .public); clearing embeddings for full re-embed"
            )
            try await store.write { db in
                try db.execute(sql: "UPDATE \(Schema.TsChunks.table) SET \(Schema.TsChunks.embedding) = NULL")
                try db.execute(sql: "UPDATE \(Schema.IndexedFiles.table) SET \(Schema.IndexedFiles.embedded) = 0")
            }
        }
        try await store.setEmbedderDimension(embedder.dimension)
    }

    /// Embeds `filePath`'s `ts_chunks` texts in one batched call and writes
    /// the resulting vectors back, or leaves the file's chunks untouched
    /// (still `NULL`, still `embedded = 0`) on any failure.
    ///
    /// A file with no chunks (e.g. one with no chunkable nodes) is
    /// vacuously fully embedded and marked as such without calling
    /// `embedder`. Otherwise, `embedder.embed(_:)` throwing, or returning a
    /// vector count that doesn't match the chunk count, is logged and
    /// treated as a graceful skip — never a crash, and never a partial
    /// write: a file's chunks are all embedded or none are.
    private static func embedChunks(forFilePath filePath: String, embedder: TextEmbedding, store: Store) async throws {
        let chunks: [EmbeddableChunk] = try await store.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT \(Schema.TsChunks.id), \(Schema.TsChunks.text) FROM \(Schema.TsChunks.table) \
                WHERE \(Schema.TsChunks.filePath) = ? ORDER BY \(Schema.TsChunks.id)
                """,
                arguments: [filePath]
            ).map { row in
                EmbeddableChunk(id: row[Schema.TsChunks.id], text: row[Schema.TsChunks.text])
            }
        }

        guard !chunks.isEmpty else {
            try await store.markIndexed(filePath: filePath, layer: .embedding)
            return
        }

        let vectors: [[Float]]
        do {
            vectors = try await embedder.embed(chunks.map(\.text))
        } catch {
            Log.embedding.warning(
                "embedder threw for \(filePath, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return
        }

        guard vectors.count == chunks.count else {
            Log.embedding.warning(
                "embedder returned \(vectors.count) vectors for \(chunks.count) chunks in \(filePath, privacy: .public); skipping"
            )
            return
        }

        try await store.write { db in
            for (chunk, vector) in zip(chunks, vectors) {
                try db.execute(
                    sql: "UPDATE \(Schema.TsChunks.table) SET \(Schema.TsChunks.embedding) = ? WHERE \(Schema.TsChunks.id) = ?",
                    arguments: [EmbeddingCodec.encode(vector), chunk.id]
                )
            }
        }

        try await store.markIndexed(filePath: filePath, layer: .embedding)
    }
}

/// One `ts_chunks` row's identity and text, fetched for embedding.
private struct EmbeddableChunk: Sendable {
    let id: Int64
    let text: String
}
