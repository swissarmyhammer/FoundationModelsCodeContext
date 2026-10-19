import Foundation
import FoundationModelsExtras
import GRDB
import Logging
import Tracing

/// Drains `ts_indexed = 0` files from a `Store`, parses and chunks each via
/// `Chunker`, writes the resulting `SemanticChunk`s into `ts_chunks`, and
/// extracts approximate call-graph edges via `TSCallGraph` into
/// `lsp_call_edges`.
///
/// Port of the tree-sitter portion of the Rust
/// `index_discovered_files_with_embedder`
/// (`swissarmyhammer-tools/src/mcp/tools/code_context/mod.rs`): chunk
/// extraction and storage, call-graph edge extraction, plus an optional
/// embedding step. Parsing (via `Chunker.chunk(file:module:)`) always runs
/// outside any database transaction; only the `DELETE`+`INSERT` for a file's
/// chunks, its `TSCallGraph`-derived call edges, and its `ts_indexed` flag
/// flip happen inside one `Store.write` block.
///
/// When `run(store:rootDirectory:embedder:embeddingBatchSize:tracer:)` is given an
/// `embedder`, it also drains `embedded = 0` files — every file just
/// (re)chunked above, plus any
/// file left over from a prior pass that had no embedder or whose embedder
/// failed — and batch-embeds each file's chunk texts, storing vectors via
/// `EmbeddingCodec`. Without an `embedder`, every written row's `embedding`
/// column stays `NULL`, exactly as before this integration.
public enum TreeSitterWorker {
    /// The default maximum number of chunk texts in one `embed(texts:)` call.
    /// One call can hold the chunks of more than one file.
    ///
    /// The value is 256 for these reasons:
    ///
    /// - The MLX embedder of FoundationModelsExtras sorts the texts of one
    ///   call by token count, and divides them into sub-batches of 16,384
    ///   tokens at most, (texts) x (longest text). 256 texts of 64 tokens fill
    ///   one sub-batch. Many code chunks are that short, thus a call of 256
    ///   texts gives the sort enough texts of each length to fill full
    ///   sub-batches. A call of 32 texts fills a sub-batch only with texts of
    ///   512 tokens.
    /// - A larger call gives the sort no more advantage, but it makes each
    ///   call longer. The worker looks for task cancellation only between two
    ///   calls, and a failed call skips each file of that call. At the rate
    ///   that `IndexBenchmark` measured for the embedding step on this package
    ///   with calls of 32 texts (approximately 59 texts each second), a call
    ///   of 256 texts takes approximately 4 seconds. Thus a cancelled pass
    ///   stops in approximately 4 seconds.
    ///
    /// The bound is a number of texts, not a number of tokens. The worker
    /// does not cut a text.
    public static let defaultEmbeddingBatchSize = 256

    /// Drains and processes every file with `ts_indexed = 0` in `store`, then
    /// — if `embedder` is given — embeds every file with `embedded = 0`.
    ///
    /// For each dirty file: reads its content from disk (relative to
    /// `rootDirectory`), looks up its `LanguageModule` by extension, chunks
    /// it, replaces its `ts_chunks` rows, and marks it indexed. A file that
    /// is no longer on disk (it was removed after the event that made it
    /// dirty) is removed from the index with all its rows. Each other file is
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
    /// `PooledEmbedding` declares no vector length, thus each call of this
    /// function measures `embedder` again: the embedding step embeds one probe
    /// text before the chunks (see `MeasuredEmbedder`). `CodeContext` keeps one
    /// `MeasuredEmbedder` for its life and calls
    /// `run(store:rootDirectory:measuredEmbedder:embeddingBatchSize:tracer:)`,
    /// thus it embeds the probe one time only.
    ///
    /// - Parameters:
    ///   - store: The workspace's index store to drain and write into.
    ///   - rootDirectory: The workspace root dirty file paths are relative
    ///     to.
    ///   - embedder: The embedder to use for the embedding step, or `nil` to
    ///     skip embedding entirely, leaving chunks with a `NULL` embedding.
    ///     Defaults to `nil`.
    ///   - embeddingBatchSize: The maximum number of chunk texts in one
    ///     `embed(texts:)` call. A value less than 1 is used as 1. Defaults to
    ///     `defaultEmbeddingBatchSize`.
    ///   - tracer: The tracer of the span of each `embed(texts:)` call. Defaults
    ///     to `nil`, which reads the bootstrapped tracer at the time of each
    ///     call.
    /// - Returns: The number of dirty tree-sitter files drained this pass.
    /// - Throws: Rethrows `Store`'s storage errors. Throws `CancellationError`
    ///   when the task is cancelled. The pass looks for cancellation before
    ///   each file and before each `embed(texts:)` call, and each file that is
    ///   complete at that time stays complete.
    @discardableResult
    public static func run(
        store: Store,
        rootDirectory: URL,
        embedder: PooledEmbedding? = nil,
        embeddingBatchSize: Int = TreeSitterWorker.defaultEmbeddingBatchSize,
        tracer: (any Tracer)? = nil
    ) async throws -> Int {
        try await run(
            store: store,
            rootDirectory: rootDirectory,
            measuredEmbedder: embedder.map(MeasuredEmbedder.init(embedder:)),
            embeddingBatchSize: embeddingBatchSize,
            tracer: tracer
        )
    }

    /// Drains and processes every file with `ts_indexed = 0` in `store`, then
    /// — if `measuredEmbedder` is given — embeds every file with
    /// `embedded = 0`.
    ///
    /// Before the drain, the pass compares the embed-text version of the
    /// index with `Chunker.embeddingTextVersion` (see
    /// `reconcileEmbeddingTextVersion(store:)`).
    ///
    /// This is `run(store:rootDirectory:embedder:embeddingBatchSize:tracer:)`
    /// for a caller that keeps one `MeasuredEmbedder` for more than one pass.
    /// The measured embedder keeps the vector length that it learned, thus a
    /// pass after the first embeds no probe text.
    ///
    /// - Parameters:
    ///   - store: The workspace's index store to drain and write into.
    ///   - rootDirectory: The workspace root dirty file paths are relative
    ///     to.
    ///   - measuredEmbedder: The embedder of the embedding step and its
    ///     vector length, or `nil` to skip embedding entirely.
    ///   - embeddingBatchSize: The maximum number of chunk texts in one
    ///     `embed(texts:)` call. A value less than 1 is used as 1.
    ///   - tracer: The tracer of the span of each `embed(texts:)` call, or `nil`
    ///     to read the bootstrapped tracer at the time of each call.
    /// - Returns: The number of dirty tree-sitter files drained this pass.
    /// - Throws: Rethrows `Store`'s storage errors. Throws `CancellationError`
    ///   when the task is cancelled.
    @discardableResult
    internal static func run(
        store: Store,
        rootDirectory: URL,
        measuredEmbedder: MeasuredEmbedder?,
        embeddingBatchSize: Int,
        tracer: (any Tracer)?
    ) async throws -> Int {
        try await reconcileEmbeddingTextVersion(store: store)
        let dirtyPaths = try await store.drainTsDirty()

        for relativePath in dirtyPaths {
            try Task.checkCancellation()
            try await indexFile(relativePath: relativePath, rootDirectory: rootDirectory, store: store)
        }

        if let measuredEmbedder {
            try await embedDirtyChunks(
                measuredEmbedder: measuredEmbedder,
                store: store,
                batchSize: max(1, embeddingBatchSize),
                tracer: tracer
            )
        }

        return dirtyPaths.count
    }

    /// One dirty file's parsed content, ready for `writeChunks(file:module:chunks:store:)`.
    ///
    /// Bundles `readAndChunk(relativePath:rootDirectory:)`'s three results
    /// together — `SourceFile`, `LanguageModule`, and the chunks parsed from
    /// them — since `writeChunks(file:module:chunks:store:)` needs all three:
    /// `chunks` for the `ts_chunks` rows, and `file`/`module` again for
    /// `TSCallGraph.writeCallEdges(db:file:module:)`'s own independent parse
    /// of the same source.
    private struct ParsedFile {
        /// The file that was read and chunked.
        let file: SourceFile

        /// The language module used to chunk `file`.
        let module: any LanguageModule.Type

        /// The chunks `Chunker.chunk(file:module:)` extracted from `file`.
        let chunks: [SemanticChunk]
    }

    /// What `readAndChunk(relativePath:rootDirectory:)` gives for one dirty
    /// file, and thus what `indexFile(relativePath:rootDirectory:store:)`
    /// writes for it.
    private enum ReadOutcome {
        /// The file was read and chunked.
        case parsed(ParsedFile)

        /// No file is at the path: it was removed after the event that made
        /// it dirty. The worker removes the rows of the file.
        case missing

        /// The worker does not chunk the file, and marks it indexed with
        /// nothing written.
        case skipped
    }

    /// Indexes one dirty file, outside of the transaction of any other file.
    ///
    /// A file that was read and chunked gets its rows replaced (see
    /// `writeChunks(file:module:chunks:store:)`, which marks the file indexed
    /// itself, in the same transaction as the rows it writes). A file that is
    /// gone gets its `indexed_files` row deleted with
    /// `Store.deleteFile(filePath:)`, which cascades to its chunks (with
    /// their embeddings), symbols and call edges. This is the same delete as
    /// the delete of the watcher for a removed file and of the reconcile for
    /// a file that is no longer on disk, thus the three paths agree. Each
    /// other file is marked indexed with nothing written, so it is not tried
    /// again in each pass.
    /// - Parameters:
    ///   - relativePath: The workspace-relative path of the dirty file.
    ///   - rootDirectory: The workspace root that `relativePath` is relative to.
    ///   - store: The workspace's index store to write into.
    /// - Throws: Rethrows `Store`'s storage errors.
    private static func indexFile(relativePath: String, rootDirectory: URL, store: Store) async throws {
        switch readAndChunk(relativePath: relativePath, rootDirectory: rootDirectory) {
        case .parsed(let parsed):
            try await writeChunks(file: parsed.file, module: parsed.module, chunks: parsed.chunks, store: store)
        case .missing:
            try await store.deleteFile(filePath: relativePath)
        case .skipped:
            try await store.markIndexed(filePath: relativePath, layer: .treeSitter)
        }
    }

    /// Reads `relativePath`'s content from disk and chunks it with its
    /// registered `LanguageModule`.
    ///
    /// `relativePath` is checked with `RelativePath.isSafeRelativePath(_:)`
    /// before it is ever resolved against disk: a `..` component, or a
    /// leading `/` or `~`, is rejected the same way an unresolvable language
    /// module or an unreadable file is —
    /// `run(store:rootDirectory:embedder:embeddingBatchSize:tracer:)` marks the file
    /// tree-sitter-indexed with nothing written, so it isn't retried
    /// forever. The walker/reconciler that populates
    /// `indexed_files.file_path` should already only ever write
    /// workspace-relative paths, but this layer doesn't trust data flowing
    /// back out of the store any more than `LSPIndexWorker` trusts it.
    ///
    /// Runs entirely outside any database transaction.
    /// - Parameters:
    ///   - relativePath: The workspace-relative path of the dirty file.
    ///   - rootDirectory: The workspace root that `relativePath` is relative to.
    /// - Returns: `.parsed` with the chunks of the file, `.missing` when no
    ///   file is at the path, or `.skipped` when the path is not safe, no
    ///   language module parses the file, or the file cannot be read as
    ///   UTF-8 text.
    private static func readAndChunk(relativePath: String, rootDirectory: URL) -> ReadOutcome {
        guard RelativePath.isSafeRelativePath(relativePath) else {
            Log.index.warning(
                "the tree-sitter index worker rejects a relative path that is not safe and marks the file indexed",
                metadata: [CodeContextTracing.MetadataKey.filePath: .string(relativePath)]
            )
            return .skipped
        }

        let fileExtension = Languages.normalizedFileExtension(ofPath: relativePath)
        guard let module = Languages.module(forFileExtension: fileExtension) else {
            Log.index.warning(
                "no language module parses the file",
                metadata: [CodeContextTracing.MetadataKey.filePath: .string(relativePath)]
            )
            return .skipped
        }

        let contents: String
        do {
            contents = try SourceText.read(at: rootDirectory.appendingPathComponent(relativePath))
        } catch {
            return outcome(of: error, relativePath: relativePath)
        }

        let file = SourceFile(relativePath: relativePath, contents: contents)
        let chunks = Chunker.chunk(file: file, module: module)
        return .parsed(ParsedFile(file: file, module: module, chunks: chunks))
    }

    /// Logs why the read of `relativePath` gave no text, and gives what the
    /// worker writes for the file.
    ///
    /// A file that is gone is not an error, thus its record has the debug
    /// level. A file that is not UTF-8 text is a fact of the workspace, thus
    /// its record has the info level. Each other read failure is a warning,
    /// with the type name of the error.
    /// - Parameters:
    ///   - failure: Why the read gave no text.
    ///   - relativePath: The workspace-relative path of the file.
    /// - Returns: `.missing` for a file that is gone, else `.skipped`.
    private static func outcome(of failure: SourceText.ReadFailure, relativePath: String) -> ReadOutcome {
        var metadata: Logger.Metadata = [CodeContextTracing.MetadataKey.filePath: .string(relativePath)]
        switch failure {
        case .missing:
            Log.index.debug(
                "the tree-sitter index worker finds no file at a dirty path and removes the file from the index",
                metadata: metadata
            )
            return .missing
        case .notUTF8:
            Log.index.info(
                "the tree-sitter index worker skips a file that is not UTF-8 text and marks the file indexed",
                metadata: metadata
            )
            return .skipped
        case .unreadable(let errorType):
            metadata[CodeContextTracing.MetadataKey.errorType] = errorType
            Log.index.warning("the tree-sitter index worker cannot read the file", metadata: metadata)
            return .skipped
        }
    }

    /// Compares the embed-text version that `store` records with
    /// `Chunker.embeddingTextVersion` and, on a difference, makes the index
    /// chunk each file again and embed each chunk again.
    ///
    /// The stored embed text of a chunk comes from the chunker, thus a change
    /// of the embed-text rules needs a new chunk pass, not only a new embed
    /// pass. On a difference, one transaction clears every chunk embedding and
    /// resets the `ts_indexed` and `embedded` flags of every file. Then the
    /// function records the current version. The drain of this pass then
    /// chunks each file, and the embedding step embeds each chunk, one time.
    /// The vector length does not change, thus `reconcileEmbedderDimension`
    /// cannot see this change.
    ///
    /// An index with no recorded version has version 0. On a new index each
    /// file is already dirty, thus the reset changes nothing there.
    ///
    /// - Parameter store: The index store that records the version.
    /// - Throws: `CodeContextError.storage` if a read or a write fails.
    private static func reconcileEmbeddingTextVersion(store: Store) async throws {
        let storedVersion = try await store.embeddingTextVersion()
        guard storedVersion != Chunker.embeddingTextVersion else {
            return
        }
        Log.embedding.notice(
            "the embed-text rules changed; the index chunks all files again and embeds all chunks again",
            metadata: [
                CodeContextTracing.MetadataKey.embeddingStoredTextVersion: .stringConvertible(storedVersion),
                CodeContextTracing.MetadataKey.embeddingTextVersion: .stringConvertible(Chunker.embeddingTextVersion),
            ]
        )
        try await store.write { db in
            try clearAllEmbeddings(db: db, dirtyFlags: [Schema.IndexedFiles.tsIndexed, Schema.IndexedFiles.embedded])
        }
        try await store.setEmbeddingTextVersion(Chunker.embeddingTextVersion)
    }

    /// Replaces `file`'s `ts_chunks` rows with `chunks` and its
    /// tree-sitter-sourced `lsp_call_edges` rows with `TSCallGraph`'s
    /// heuristic edges, in one write transaction: deletes the file's
    /// existing `ts_chunks` rows (so a re-chunked, changed file doesn't
    /// accumulate stale rows alongside the new ones), inserts each chunk
    /// with a `NULL` embedding, extracts and replaces call-graph edges via
    /// `TSCallGraph.writeCallEdges(db:file:module:)`, marks the file
    /// tree-sitter-indexed, and resets its `embedded` flag to 0.
    ///
    /// The `embedding_text` column of a row holds the embed text of the chunk
    /// only when it is not the chunk text (see `storedEmbeddingText(of:)`).
    ///
    /// Call-graph edge extraction runs in the same transaction as the chunk
    /// write (rather than as a separate `store.write` call afterward) so a
    /// process interrupted mid-drain never leaves a file's chunks committed
    /// with its edges still stale, or its `ts_indexed` flag flipped before
    /// either write lands.
    ///
    /// The `embedded` reset is required even though `Store.markDirty`
    /// already zeroes it for the common (hash-changed) case: it keeps the
    /// invariant "a chunk with a `NULL` embedding belongs to a file with
    /// `embedded = 0`" true for any re-chunk, not just ones that went
    /// through `markDirty` first, so a re-chunked file's freshly written,
    /// unembedded chunks are always picked back up by the next
    /// `drainEmbeddingDirty()` pass.
    private static func writeChunks(
        file: SourceFile,
        module: any LanguageModule.Type,
        chunks: [SemanticChunk],
        store: Store
    ) async throws {
        try await store.write { db in
            try db.execute(
                sql: "DELETE FROM \(Schema.TsChunks.table) WHERE \(Schema.TsChunks.filePath) = ?",
                arguments: [file.relativePath]
            )
            for chunk in chunks {
                try db.execute(
                    sql: """
                        INSERT INTO \(Schema.TsChunks.table)
                            (\(Schema.TsChunks.filePath), \(Schema.TsChunks.startByte), \(Schema.TsChunks.endByte), \
                             \(Schema.TsChunks.startLine), \(Schema.TsChunks.endLine), \(Schema.TsChunks.text), \
                             \(Schema.TsChunks.symbolPath), \(Schema.TsChunks.kind), \(Schema.TsChunks.embeddingText))
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        chunk.filePath, chunk.startByte, chunk.endByte,
                        chunk.startLine, chunk.endLine, chunk.text,
                        chunk.symbolPath, chunk.kind.rawValue, storedEmbeddingText(of: chunk),
                    ]
                )
            }

            try TSCallGraph.writeCallEdges(db: db, file: file, module: module)

            try db.execute(
                sql: """
                    UPDATE \(Schema.IndexedFiles.table) \
                    SET \(Schema.IndexedFiles.tsIndexed) = 1, \(Schema.IndexedFiles.embedded) = 0 \
                    WHERE \(Schema.IndexedFiles.filePath) = ?
                    """,
                arguments: [file.relativePath]
            )
        }
    }

    /// Gives the value of the `embedding_text` column of `chunk`: its embed
    /// text, or `nil` when the embed text is the chunk text.
    ///
    /// Only a container chunk has an embed text that is not its text. Thus
    /// the column does not hold a second copy of the text of each other
    /// chunk. `embeddableChunks(ofFilePath:store:)` reads
    /// `COALESCE(embedding_text, text)`.
    private static func storedEmbeddingText(of chunk: SemanticChunk) -> String? {
        chunk.embeddingText == chunk.text ? nil : chunk.embeddingText
    }

    // MARK: - Embedding

    /// Batch-embeds every chunk of every file with `embedded = 0`, writing
    /// vectors through `EmbeddingCodec` and marking each file's `embedded`
    /// flag once each of its chunks has a vector.
    ///
    /// One `embed(texts:)` call holds `batchSize` texts at most, and it can
    /// hold the chunks of more than one file (see `EmbeddingCallQueue`). The
    /// step reads the chunks of the dirty files in path order, and sends a
    /// call each time `batchSize` texts are ready. The last call holds the
    /// texts that are left. A file with no chunks is marked embedded at once.
    /// When a call fails, the step skips each file of that call, and a later
    /// pass embeds those files again (see `embedNextCall`).
    ///
    /// Before draining, gets the dimension of the embedder from the length of
    /// the first vector that it returns (see `measureDimension`), and
    /// reconciles that dimension against the one recorded in `meta` the last
    /// time embedding ran (see `reconcileEmbedderDimension`): a mismatch
    /// clears every chunk's embedding and every file's `embedded` flag, so
    /// the drain below picks up the whole index for full re-embedding instead
    /// of leaving stale, wrong-dimension vectors in place. This runs
    /// regardless of how many files the tree-sitter pass just chunked —
    /// including a pass with zero dirty files, which is how a dimension change
    /// alone (no source changes) still triggers a full re-embed.
    ///
    /// When the embedder gives no dimension, the step embeds nothing. Each
    /// dirty file stays dirty, thus a later pass embeds it.
    ///
    /// The step looks for task cancellation before each file, and
    /// `embedNextCall` looks for it before each call, thus a cancelled pass
    /// stops after one call at most. Each file that is complete at that time
    /// stays complete.
    ///
    /// Each `embed(texts:)` call runs in its own span through `tracer`.
    private static func embedDirtyChunks(
        measuredEmbedder: MeasuredEmbedder,
        store: Store,
        batchSize: Int,
        tracer: (any Tracer)?
    ) async throws {
        guard let dimension = try await measureDimension(of: measuredEmbedder, tracer: tracer) else {
            return
        }
        try await reconcileEmbedderDimension(dimension, store: store)

        let embedder = measuredEmbedder.embedder
        var queue = EmbeddingCallQueue()
        for filePath in try await store.drainEmbeddingDirty() {
            try Task.checkCancellation()
            let chunks = try await embeddableChunks(ofFilePath: filePath, store: store)
            guard !chunks.isEmpty else {
                // A file with no chunks is fully embedded with no call.
                try await store.markIndexed(filePath: filePath, layer: .embedding)
                continue
            }
            queue.append(filePath: filePath, chunks: chunks)
            while queue.unsentCount >= batchSize {
                try await embedNextCall(from: &queue, embedder: embedder, store: store, batchSize: batchSize, tracer: tracer)
            }
        }
        while !queue.isEmpty {
            try await embedNextCall(from: &queue, embedder: embedder, store: store, batchSize: batchSize, tracer: tracer)
        }
    }

    /// Gives the dimension of the embedder: the length of the first vector
    /// that it returns.
    ///
    /// When the embedder has returned no vector yet, `measuredEmbedder`
    /// embeds one probe text. When that probe fails, or gives no vector, the
    /// function writes a warning and gives `nil`: the pass then skips the
    /// embedding step, and a later pass measures again.
    ///
    /// - Parameters:
    ///   - measuredEmbedder: The embedder and the vector length that it knows.
    ///   - tracer: The tracer of the span of the probe call.
    /// - Returns: The dimension, or `nil` when the embedder gives none.
    /// - Throws: `CancellationError` when the task is cancelled.
    private static func measureDimension(of measuredEmbedder: MeasuredEmbedder, tracer: (any Tracer)?) async throws -> Int? {
        do {
            return try await measuredEmbedder.vectorLength(tracer: tracer)
        } catch {
            // A cancelled embedder can throw an error of its own type.
            // A cancelled pass must stop, not skip the step and continue.
            try Task.checkCancellation()
            Log.embedding.warning(
                "the embedder gave no vector length; the pass skips the embedding step",
                metadata: [CodeContextTracing.MetadataKey.errorType: Log.errorType(of: error)]
            )
            return nil
        }
    }

    /// Compares `dimension` against the dimension stored in `meta` and, on a
    /// mismatch, clears every chunk's embedding and resets every file's
    /// `embedded` flag so the next drain fully re-embeds the index.
    ///
    /// No stored dimension (a fresh index, or one that has never embedded)
    /// is not a mismatch — it just records the current dimension.
    ///
    /// - Parameters:
    ///   - dimension: The length of the first vector that the embedder
    ///     returned.
    ///   - store: The index store that records the dimension.
    private static func reconcileEmbedderDimension(_ dimension: Int, store: Store) async throws {
        let storedDimension = try await store.embedderDimension()
        if let storedDimension, storedDimension != dimension {
            Log.embedding.notice(
                "the embedder dimension changed; the index clears all embeddings and embeds all chunks again",
                metadata: [
                    CodeContextTracing.MetadataKey.embeddingStoredDimension: .stringConvertible(storedDimension),
                    CodeContextTracing.MetadataKey.embeddingDimension: .stringConvertible(dimension),
                ]
            )
            try await store.write { db in
                try clearAllEmbeddings(db: db, dirtyFlags: [Schema.IndexedFiles.embedded])
            }
        }
        try await store.setEmbedderDimension(dimension)
    }

    /// Clears the embedding of every chunk and sets each column of
    /// `dirtyFlags` to 0 for every file, so that the next drain of those
    /// layers picks up the whole index.
    ///
    /// Shared by `reconcileEmbedderDimension` and
    /// `reconcileEmbeddingTextVersion(store:)`. Each caller runs it in its
    /// own write transaction.
    ///
    /// - Parameters:
    ///   - db: The database connection of the write transaction.
    ///   - dirtyFlags: The `indexed_files` flag columns to set to 0.
    /// - Throws: The error of a failed `UPDATE`.
    private static func clearAllEmbeddings(db: Database, dirtyFlags: [String]) throws {
        try db.execute(sql: "UPDATE \(Schema.TsChunks.table) SET \(Schema.TsChunks.embedding) = NULL")
        let assignments = dirtyFlags.map { "\($0) = 0" }.joined(separator: ", ")
        try db.execute(sql: "UPDATE \(Schema.IndexedFiles.table) SET \(assignments)")
    }

    /// Sends the next call of `queue` to the embedder, and writes each file
    /// that the call makes complete.
    ///
    /// The function looks for task cancellation before the call. When the
    /// call fails (see `embed(_:with:tracer:)`), the function skips each file
    /// of the call: each chunk of the file keeps a `NULL` embedding and the
    /// file keeps `embedded = 0`, thus a later pass embeds it again. The other
    /// files of `queue` do not change.
    ///
    /// - Parameters:
    ///   - queue: The chunks that do not have a vector yet. One chunk or more
    ///     of the queue is not in a call yet.
    ///   - embedder: The embedder that makes the vectors.
    ///   - store: The index store to write the vectors into.
    ///   - batchSize: The maximum number of texts in the call. The value is 1
    ///     or more.
    ///   - tracer: The tracer of the span of the call.
    /// - Throws: `CancellationError` when the task is cancelled. Rethrows the
    ///   storage errors of `store`.
    private static func embedNextCall(
        from queue: inout EmbeddingCallQueue,
        embedder: PooledEmbedding,
        store: Store,
        batchSize: Int,
        tracer: (any Tracer)?
    ) async throws {
        try Task.checkCancellation()
        let call = queue.nextCall(maxTextCount: batchSize)
        guard let vectors = try await embed(call, with: embedder, tracer: tracer) else {
            queue.skip(call)
            return
        }
        try await writeVectors(of: queue.complete(call, vectors: vectors), store: store)
    }

    /// Embeds the texts of `call` in one `embed(texts:)` call.
    ///
    /// When `embedder.embed(texts:)` throws, or returns a vector count that is
    /// not the text count, the function writes one log entry for each file of
    /// the call and returns `nil`, and the caller skips those files.
    ///
    /// - Parameters:
    ///   - call: The texts to embed, and the file of each text.
    ///   - embedder: The embedder that makes the vectors.
    ///   - tracer: The tracer of the span of the call.
    /// - Returns: One vector for each text of `call`, in the order of its
    ///   texts, or `nil` when the caller must skip the files of the call.
    /// - Throws: `CancellationError` when the task is cancelled.
    private static func embed(_ call: EmbeddingCall, with embedder: PooledEmbedding, tracer: (any Tracer)?) async throws -> [[Float]]? {
        let vectors: [[Float]]
        do {
            vectors = try await CodeContextSpans.embed(call.texts, with: embedder, tracer: tracer)
        } catch {
            // A cancelled embedder can throw an error of its own type.
            // A cancelled pass must stop, not skip the files and continue.
            try Task.checkCancellation()
            for filePath in call.filePaths {
                Log.embedding.warning(
                    "the embedder failed; the index skips the file",
                    metadata: [
                        CodeContextTracing.MetadataKey.filePath: .string(filePath),
                        CodeContextTracing.MetadataKey.errorType: Log.errorType(of: error),
                    ]
                )
            }
            return nil
        }
        guard vectors.count == call.texts.count else {
            for filePath in call.filePaths {
                Log.embedding.warning(
                    "the embedder returned a vector count that is not the chunk count; the index skips the file",
                    metadata: [
                        CodeContextTracing.MetadataKey.filePath: .string(filePath),
                        CodeContextTracing.MetadataKey.embeddingInputCount: .stringConvertible(call.texts.count),
                        CodeContextTracing.MetadataKey.embeddingOutputCount: .stringConvertible(vectors.count),
                    ]
                )
            }
            return nil
        }
        return vectors
    }

    /// The name of the result column of `embeddableChunks(ofFilePath:store:)`
    /// that holds the text to embed: the embed text of a container chunk,
    /// else the chunk text.
    private static let embeddableTextColumn = "embeddable_text"

    /// Reads the `ts_chunks` rows of `filePath` and the text to embed for
    /// each row.
    ///
    /// - Parameters:
    ///   - filePath: The path of the file.
    ///   - store: The index store to read.
    /// - Returns: The chunks of the file, in identifier order. A file with no
    ///   chunkable nodes has no chunks.
    /// - Throws: `CodeContextError.storage` if the read fails.
    private static func embeddableChunks(ofFilePath filePath: String, store: Store) async throws -> [EmbeddableChunk] {
        try await store.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT \(Schema.TsChunks.id), \
                    COALESCE(\(Schema.TsChunks.embeddingText), \(Schema.TsChunks.text)) AS \(embeddableTextColumn) \
                    FROM \(Schema.TsChunks.table) \
                    WHERE \(Schema.TsChunks.filePath) = ? ORDER BY \(Schema.TsChunks.id)
                    """,
                arguments: [filePath]
            ).map { row in
                EmbeddableChunk(id: row[Schema.TsChunks.id], text: row[embeddableTextColumn])
            }
        }
    }

    /// Writes the vectors of each file of `files`, and marks each file
    /// embedded, in one `Store.write` transaction.
    ///
    /// Each file of `files` has a vector for each of its chunks, thus a file
    /// is written whole or not at all. The chunk embedding `UPDATE`s of a file
    /// and its `embedded = 1` flip are in the same transaction. Thus no reader
    /// sees a chunk with a vector while its file has `embedded = 0`, or the
    /// reverse.
    ///
    /// - Parameters:
    ///   - files: The complete files. An empty value writes nothing.
    ///   - store: The index store to write into.
    /// - Throws: `CodeContextError.storage` if the write fails.
    private static func writeVectors(of files: [EmbeddedFile], store: Store) async throws {
        guard !files.isEmpty else {
            return
        }
        try await store.write { db in
            for file in files {
                for (chunk, vector) in zip(file.chunks, file.vectors) {
                    try db.execute(
                        sql: "UPDATE \(Schema.TsChunks.table) SET \(Schema.TsChunks.embedding) = ? WHERE \(Schema.TsChunks.id) = ?",
                        arguments: [EmbeddingCodec.encode(vector), chunk.id]
                    )
                }
                try db.execute(
                    sql: "UPDATE \(Schema.IndexedFiles.table) SET \(Schema.IndexedFiles.embedded) = 1 WHERE \(Schema.IndexedFiles.filePath) = ?",
                    arguments: [file.filePath]
                )
            }
        }
    }
}
