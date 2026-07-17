import Foundation
import GRDB
import FoundationModelsRanker

/// `FoundationModelsRanker`'s updateable, additive retrieval index — the
/// container this workspace's `SearchCorpus` splices per-file, aliased here so
/// its bare name never collides with this module's own `SearchCorpus`.
private typealias RankerIndex = FoundationModelsRanker.SearchCorpus

/// A cached, contiguous snapshot of one workspace's `ts_chunks` table, ready
/// for BM25/trigram keyword scoring and `vDSP_mmul` cosine scoring — the
/// data `SearchCode.run(corpus:embedder:query:topK:weights:)` ranks against.
///
/// See plan.md "Search", "Where the cosines happen": chunk embeddings live in
/// one contiguous row-major `[Float]` matrix (`chunkCount` rows ×
/// `embeddingDimension` columns) rather than as `chunkCount` separate
/// arrays, so scoring every chunk against a query vector is one
/// `vDSP_mmul` matrix–vector product instead of `chunkCount` separate
/// dot-product loops. BM25/trigram data is likewise precomputed once per
/// chunk when the snapshot is built — tokenizing and trigramming
/// `chunkCount` texts is the expensive part — rather than once per query.
public struct SearchCorpusSnapshot: Sendable {
    /// Each chunk's `ts_chunks.id`, positionally aligned with every other
    /// array in this type.
    public let chunkIDs: [Int64]

    /// Each chunk's file path, positionally aligned with `chunkIDs`.
    public let filePaths: [String]

    /// Each chunk's qualified symbol path, positionally aligned with
    /// `chunkIDs`.
    public let symbolPaths: [String]

    /// Each chunk's full source text, positionally aligned with `chunkIDs`.
    public let texts: [String]

    /// Each chunk's meta-type, positionally aligned with `chunkIDs`.
    public let kinds: [SymbolMetaType]

    /// Each chunk's zero-based start line, positionally aligned with
    /// `chunkIDs`.
    public let startLines: [Int]

    /// Each chunk's zero-based end line, positionally aligned with
    /// `chunkIDs`.
    public let endLines: [Int]

    /// Whether each chunk carries a usable (non-`NULL`,
    /// `embeddingDimension`-length) embedding, positionally aligned with
    /// `chunkIDs`. A chunk without one contributes an all-zero row to
    /// `embeddingMatrix`, which — since every real embedding is
    /// L2-normalized — scores an exact `0.0` cosine against any query,
    /// matching `Signals.cosine`'s documented "no embedding" value.
    public let embeddedFlags: [Bool]

    /// The dimension of every row in `embeddingMatrix`; `0` if no chunk in
    /// the corpus has an embedding yet.
    public let embeddingDimension: Int

    /// The corpus's embeddings as one contiguous, row-major `chunkCount ×
    /// embeddingDimension` matrix — row `i` is `chunkIDs[i]`'s embedding (or
    /// an all-zero row if `embeddedFlags[i]` is `false`). Not `public`:
    /// `cosineScores(queryVector:)` is the sanctioned way to score it.
    let embeddingMatrix: [Float]

    /// Each chunk's precomputed BM25/trigram statistics — `symbolPaths[i]`
    /// as the primary field (weighted `BM25.primaryFieldWeight`), `texts[i]`
    /// as the body field (weighted `BM25.bodyFieldWeight`) — positionally
    /// aligned with `chunkIDs`. `FoundationModelsRanker.RankedDocument` carries the
    /// weighted term frequency, term set, document length, and both trigram
    /// sets the BM25/trigram scoring stages consume.
    let rankedDocuments: [RankedDocument]

    /// The number of chunks in this snapshot.
    public var chunkCount: Int { chunkIDs.count }

    /// The number of chunks with `embeddedFlags[i] == true`.
    public var embeddedChunkCount: Int { embeddedFlags.count { $0 } }

    /// Scores every chunk's cosine similarity against `queryVector` with one
    /// `vDSP_mmul` matrix–vector product over `embeddingMatrix`.
    ///
    /// Both `embeddingMatrix`'s rows and `queryVector` must already be
    /// L2-normalized (the injected `TextEmbedding` guarantees this for its
    /// own output), so cosine similarity reduces to a plain dot product —
    /// see plan.md "Search", "Where the cosines happen".
    ///
    /// - Parameter queryVector: The L2-normalized query embedding, of length
    ///   `embeddingDimension`.
    /// - Returns: One score per chunk, positionally aligned with `chunkIDs`;
    ///   every score is `0.0` if `queryVector`'s length doesn't match
    ///   `embeddingDimension` or the corpus has no chunks.
    public func cosineScores(queryVector: [Float]) -> [Float] {
        CosineScoring.matvecScores(
            matrix: embeddingMatrix,
            rowCount: chunkCount,
            dimension: embeddingDimension,
            queryVector: queryVector
        )
    }
}

/// Owns one workspace's lazily-loaded `SearchCorpusSnapshot` cache, kept
/// current by **incremental, per-file re-index** rather than a wholesale
/// reload on every write.
///
/// See plan.md "Search", "Where the cosines happen": a `SearchCorpus` is
/// meant to be created once (e.g. by `CodeContext`) and reused across every
/// `SearchCode.run(corpus:embedder:query:topK:weights:)` call. A file that
/// finishes indexing shows up on the very next call — no explicit
/// invalidation call, no process restart — because `snapshot()` reacts to
/// `store.generation` advancing.
///
/// **The retrieval index is `FoundationModelsRanker.SearchCorpus`.** Each
/// chunk becomes one row of that additive, updateable index — the chunk's
/// integer `ts_chunks.id` (as a `String`) is its id, its qualified symbol
/// path is the primaryText field (BM25/trigram-weighted `BM25.primaryFieldWeight`,
/// via `Searchable.primaryText`), its source text is the body field, and its
/// **file path is the eviction group**. The Ranker index owns each row's
/// tokenized/trigrammed `RankedDocument` (built once, at add time, by
/// `RankerIndex.add(items:)`) and its decoded embedding vector
/// (`RankerIndex.setEmbedding(_:forID:ifTextMatches:)` /
/// `embedding(forID:)`), so this type stores neither redundantly.
///
/// **Incremental lifecycle.** Editing a file is `remove(group:) + add(items:)`
/// on the Ranker index — exactly the group-keyed additive streaming shape
/// `FoundationModelsRanker.SearchCorpus` is built for (its motivating group
/// key is a session id; ours is a file path). When `generation` advances,
/// `snapshot()` runs one cheap scan of `ts_chunks` (ids and embedding byte
/// lengths only — no text, no embedding blobs) to find which files' chunks
/// actually changed, evicts each changed or deleted file's rows from the
/// index by group, and re-adds only the changed files' rows — reusing every
/// untouched row's precompute and stored embedding verbatim, since the
/// Ranker index never re-tokenizes or re-embeds a surviving row. The packed
/// cosine matrix is repacked from the index's per-row embeddings (a `memcpy`
/// of already-decoded vectors — no re-embedding). The BM25 corpus globals
/// (`idf`/`avgdl`) aren't cached at all: `SearchCode` rebuilds them per query
/// from the live snapshot, so they are always correct after any incremental
/// splice, exactly as after a from-scratch load.
///
/// **Full reload stays the cold-start path and the fallback.** The very first
/// `snapshot()` (empty cache) loads every row in one query and adds them all
/// to a fresh index — identical to the pre-incremental behavior — and any
/// state the incremental path can't reason about locally (a file whose
/// signature changed) resolves to re-loading that file's rows from `store`,
/// the durable source of truth.
///
/// **What the Ranker index can't carry, and this type keeps beside it.**
/// `FoundationModelsRanker.SearchCorpus`'s row holds only text, summary,
/// group, and embedding, and exposes embeddings per-row rather than as a
/// packed matrix. So two things stay local: (1) a per-file `FileEntry` of the
/// change **signature** (for the cheap diff) plus each chunk's result
/// **metadata** — file path, symbol path as a plain string, kind, and line
/// range — none of which the index can round-trip; and (2) the contiguous
/// `vDSP_mmul` cosine **matrix**, repacked at assembly from the index's
/// per-row vectors, which `SearchCorpusSnapshot.cosineScores(queryVector:)`
/// and its matvec tests depend on.
public actor SearchCorpus {
    private let store: Store

    /// The current cache: the generation it was built at, the per-file
    /// entries it was assembled from (for the next incremental diff), the
    /// Ranker retrieval index those entries index into, and the assembled
    /// snapshot itself. `nil` until the first `snapshot()`.
    private var cache: Cache?

    /// The number of chunks re-tokenized (a fresh `RankedDocument` built by
    /// `RankerIndex.add(items:)`) during the most recent `snapshot()` that
    /// rebuilt the cache — the whole corpus on a cold start, only the changed
    /// files' chunks on an incremental update, and `0` when a generation bump
    /// changed no `ts_chunks` row. Internal, for the perf-guard tests.
    private(set) var lastBuildReTokenizedChunkCount = 0

    /// The number of embedding blobs decoded during the most recent
    /// `snapshot()` that rebuilt the cache — a subset of
    /// `lastBuildReTokenizedChunkCount` (only chunks that carry an embedding).
    /// Internal, for the cosine repack tests.
    private(set) var lastBuildReDecodedChunkCount = 0

    /// Creates a corpus cache over `store`, with no snapshot loaded yet —
    /// the first `snapshot()` call performs the initial load.
    ///
    /// - Parameter store: The workspace's index store `snapshot()` loads
    ///   `ts_chunks` from.
    public init(store: Store) {
        self.store = store
    }

    /// Returns the current corpus snapshot, incrementally re-indexing any
    /// file whose chunks changed since the cache was built (or loading the
    /// whole corpus on the first call).
    ///
    /// - Returns: The up-to-date snapshot.
    /// - Throws: Rethrows `Store`'s storage errors.
    public func snapshot() async throws -> SearchCorpusSnapshot {
        let currentGeneration = store.generation
        if let cache, cache.generation == currentGeneration {
            return cache.snapshot
        }
        return try await rebuild(currentGeneration: currentGeneration)
    }

    // MARK: - Cache types

    /// The corpus's cached state between `snapshot()` calls.
    private struct Cache {
        /// The `store.generation` this cache is valid for.
        var generation: Int

        /// The per-file entries the snapshot was assembled from, keyed by
        /// file path — the input to the next incremental diff, and the
        /// per-chunk result metadata the Ranker index can't carry.
        var files: [String: FileEntry]

        /// The Ranker retrieval index `files`' chunks index into: one row per
        /// chunk (id = `ts_chunks.id` as a `String`, primaryText = symbol
        /// path, body = text, group = file path), plus each row's decoded
        /// embedding. Spliced per file by `remove(group:) + add(items:)`.
        var index: RankerIndex

        /// The assembled snapshot handed to callers.
        var snapshot: SearchCorpusSnapshot
    }

    /// One file's cached precompute: the change signature that decides
    /// whether it must be reloaded, and its chunks' result metadata.
    private struct FileEntry: Sendable {
        /// This file's chunks' `(id, embeddingByteCount)` pairs in id order —
        /// the cheap fingerprint compared against a fresh scan to detect a
        /// re-chunk (new ids), an embedding fill-in, or an embedding dimension
        /// change (byte count moves) (see `SignatureEntry`).
        let signature: [SignatureEntry]

        /// This file's chunks' result metadata, in id order — the fields the
        /// Ranker index doesn't round-trip (file path, symbol path as a plain
        /// string, kind, line range), joined back to the index's per-row
        /// retrieval state at assembly by id.
        let chunks: [ChunkMetadata]
    }

    /// One chunk's contribution to a file's change signature: its id and its
    /// embedding blob's byte length (`0` when it has no embedding). Captures
    /// every way a chunk can change the snapshot without reading any text or
    /// decoding any vector:
    /// - a re-chunk assigns new ids (bodies/symbols/kinds/lines only ever
    ///   change together with a new id, since `TreeSitterWorker` re-chunks a
    ///   file by `DELETE`+`INSERT` with fresh autoincrement ids);
    /// - embedding a chunk moves its byte length from `0` to non-zero;
    /// - an embedder **dimension** change re-embeds in place (same id,
    ///   still non-`NULL`) but at a different vector width, which the byte
    ///   length reflects — `idf`/`avgdl` aside, this is the case a bare
    ///   presence flag would miss, leaving stale vectors and a wrong
    ///   `embeddingDimension` cached.
    ///
    /// `length(embedding)` is computed by SQLite without materializing the
    /// blob, so the scan stays cheap. The one residual it can't see is an
    /// in-place re-embed that keeps the exact same id **and** byte width but a
    /// different vector value — only reachable by forcing a re-embed
    /// (`IndexAdmin.rebuildIndex(layer: .embedding)`) under a *different*
    /// same-dimension embedder; short of hashing every blob on every scan
    /// (which would defeat the cheap-scan design) that case resolves on the
    /// next real re-chunk or dimension change.
    private struct SignatureEntry: Equatable, Sendable {
        let id: Int64
        let embeddingByteCount: Int
    }

    /// One `ts_chunks` row's result metadata — the fields
    /// `FoundationModelsRanker.SearchCorpus`'s row doesn't carry (its row is
    /// only text/summary/group/embedding), kept beside the Ranker index and
    /// joined back to it by id at assembly.
    private struct ChunkMetadata: Sendable {
        let id: Int64
        let filePath: String
        let symbolPath: String
        let kind: SymbolMetaType
        let startLine: Int
        let endLine: Int
    }

    /// One `ts_chunks` row as loaded from disk, before it is spliced into the
    /// Ranker index.
    private struct ChunkRow: Sendable {
        let id: Int64
        let filePath: String
        let startLine: Int
        let endLine: Int
        let text: String
        let symbolPath: String
        let kind: SymbolMetaType
        let embedding: Data?
    }

    // MARK: - Rebuild

    /// Rebuilds the cache for `currentGeneration`: a full load on cold start,
    /// otherwise an incremental splice of only the files whose chunks
    /// changed.
    private func rebuild(currentGeneration: Int) async throws -> SearchCorpusSnapshot {
        guard let existing = cache else {
            // Cold start: load every file in one query and add every row to a
            // fresh index, exactly as before the incremental path existed.
            let rowsByFile = try await loadAllRows()

            var index = RankerIndex()
            var files: [String: FileEntry] = [:]
            var reTokenized = 0
            var reDecoded = 0
            for (path, rows) in rowsByFile {
                let spliced = splice(path: path, rows: rows, into: &index)
                files[path] = spliced.entry
                reTokenized += spliced.addedCount
                reDecoded += spliced.decodedCount
            }
            lastBuildReTokenizedChunkCount = reTokenized
            lastBuildReDecodedChunkCount = reDecoded

            let snapshot = assemble(files: files, index: index)
            cache = Cache(generation: currentGeneration, files: files, index: index, snapshot: snapshot)
            return snapshot
        }

        // Incremental: one cheap scan tells us which files changed.
        let signatures = try await loadSignatures()
        let cachedPaths = Set(existing.files.keys)
        let livePaths = Set(signatures.keys)

        let removedPaths = cachedPaths.subtracting(livePaths)
        let changedPaths = signatures.compactMap { path, signature in
            existing.files[path]?.signature == signature ? nil : path
        }

        guard !removedPaths.isEmpty || !changedPaths.isEmpty else {
            // Generation advanced without touching any `ts_chunks` row (e.g. a
            // dirty-flag flip): reuse the snapshot untouched, just revalidate
            // it for this generation so the next call short-circuits.
            lastBuildReTokenizedChunkCount = 0
            lastBuildReDecodedChunkCount = 0
            cache = Cache(
                generation: currentGeneration, files: existing.files, index: existing.index, snapshot: existing.snapshot
            )
            return existing.snapshot
        }

        let reloadedRows = try await loadRows(paths: changedPaths)

        // The whole splice is synchronous, after the last `await` — never
        // mutating the index or the counters across a suspension point, where
        // actor reentrancy could interleave another `snapshot()`.
        var index = existing.index
        var files = existing.files
        for path in removedPaths {
            index.remove(group: path)
            files[path] = nil
        }
        var reTokenized = 0
        var reDecoded = 0
        for path in changedPaths {
            // Evict the file's old rows by group, then re-add its new ones —
            // the group-keyed additive splice. The chunk ids are fresh
            // autoincrement values (a re-chunk `DELETE`+`INSERT`s), so the
            // re-add never collides with the just-evicted rows.
            index.remove(group: path)
            let spliced = splice(path: path, rows: reloadedRows[path] ?? [], into: &index)
            files[path] = spliced.entry
            reTokenized += spliced.addedCount
            reDecoded += spliced.decodedCount
        }
        lastBuildReTokenizedChunkCount = reTokenized
        lastBuildReDecodedChunkCount = reDecoded

        let snapshot = assemble(files: files, index: index)
        cache = Cache(generation: currentGeneration, files: files, index: index, snapshot: snapshot)
        return snapshot
    }

    /// Adds one file's `rows` to `index` (id = `ts_chunks.id` as a `String`,
    /// primaryText = symbol path, body = text, group = `path`), decodes and
    /// stores each row's embedding on its index row, and returns the file's
    /// `FileEntry` (change signature + result metadata) alongside the
    /// re-tokenize/re-decode counts this splice incurred.
    ///
    /// Caller-ordered: any prior rows for `path` must already have been
    /// evicted (`index.remove(group: path)`) so the id-unique re-add never
    /// hits `add(items:)`'s duplicate-id drop.
    ///
    /// - Parameters:
    ///   - path: the file whose rows these are — the index eviction group.
    ///   - rows: the file's `ts_chunks` rows, in id order.
    ///   - index: the Ranker index to add into, mutated in place.
    /// - Returns: the file's cache entry, the number of rows added (each a
    ///   fresh `RankedDocument`), and the number of embeddings decoded.
    private func splice(
        path: String, rows: [ChunkRow], into index: inout RankerIndex
    ) -> (entry: FileEntry, addedCount: Int, decodedCount: Int) {
        let items = rows.map { row in
            SearchItem(id: String(row.id), text: row.text, primaryText: row.symbolPath, group: path)
        }
        let addedCount = index.add(items: items).count

        var decodedCount = 0
        for row in rows {
            guard let blob = row.embedding else { continue }
            index.setEmbedding(EmbeddingCodec.decode(blob), forID: String(row.id), ifTextMatches: row.text)
            decodedCount += 1
        }

        let signature = rows.map { SignatureEntry(id: $0.id, embeddingByteCount: $0.embedding?.count ?? 0) }
        let chunks = rows.map { row in
            ChunkMetadata(
                id: row.id,
                filePath: row.filePath,
                symbolPath: row.symbolPath,
                kind: row.kind,
                startLine: row.startLine,
                endLine: row.endLine
            )
        }
        return (FileEntry(signature: signature, chunks: chunks), addedCount, decodedCount)
    }

    // MARK: - Loading

    /// Scans every `ts_chunks` row's id and embedding byte length — no text,
    /// no embedding blobs (`length(embedding)` is evaluated by SQLite without
    /// materializing the blob) — grouped into the per-file change signatures
    /// the incremental diff compares against the cache. `O(rows)` but cheap:
    /// the expensive tokenize/decode work is deferred to only the files this
    /// scan proves changed.
    private func loadSignatures() async throws -> [String: [SignatureEntry]] {
        let rows: [(filePath: String, entry: SignatureEntry)] = try await store.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT \(Schema.TsChunks.filePath), \(Schema.TsChunks.id), \
                       COALESCE(LENGTH(\(Schema.TsChunks.embedding)), 0) AS embeddingByteCount \
                FROM \(Schema.TsChunks.table) ORDER BY \(Schema.TsChunks.filePath), \(Schema.TsChunks.id)
                """
            ).map { row in
                (
                    filePath: row[Schema.TsChunks.filePath],
                    entry: SignatureEntry(id: row[Schema.TsChunks.id], embeddingByteCount: row["embeddingByteCount"])
                )
            }
        }

        return Dictionary(grouping: rows, by: \.filePath).mapValues { $0.map(\.entry) }
    }

    /// Loads every `ts_chunks` row in one query — the cold-start bulk load —
    /// grouped by file path.
    private func loadAllRows() async throws -> [String: [ChunkRow]] {
        let rows = try await fetchRows(sql: """
            \(Self.rowColumns) \
            FROM \(Schema.TsChunks.table) ORDER BY \(Schema.TsChunks.filePath), \(Schema.TsChunks.id)
            """)

        return Dictionary(grouping: rows, by: \.filePath)
    }

    /// Loads exactly `paths`' rows — the incremental reload — one query per
    /// file so the bound-parameter count stays fixed regardless of corpus
    /// size.
    private func loadRows(paths: [String]) async throws -> [String: [ChunkRow]] {
        var rowsByFile: [String: [ChunkRow]] = [:]
        for path in paths {
            rowsByFile[path] = try await fetchRows(
                sql: """
                    \(Self.rowColumns) \
                    FROM \(Schema.TsChunks.table) WHERE \(Schema.TsChunks.filePath) = ? ORDER BY \(Schema.TsChunks.id)
                    """,
                arguments: [path]
            )
        }
        return rowsByFile
    }

    /// The `SELECT` column list shared by `loadAllRows()` and
    /// `loadRows(paths:)`, which differ only in their `WHERE`/`ORDER BY`.
    private static let rowColumns = """
        SELECT \(Schema.TsChunks.id), \(Schema.TsChunks.filePath), \(Schema.TsChunks.startLine), \
               \(Schema.TsChunks.endLine), \(Schema.TsChunks.text), \(Schema.TsChunks.symbolPath), \
               \(Schema.TsChunks.kind), \(Schema.TsChunks.embedding)
        """

    /// Runs `sql` (with `arguments`) and maps each result row into a
    /// `ChunkRow`.
    private func fetchRows(sql: String, arguments: StatementArguments = StatementArguments()) async throws -> [ChunkRow] {
        try await store.read { db in
            try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
                ChunkRow(
                    id: row[Schema.TsChunks.id],
                    filePath: row[Schema.TsChunks.filePath],
                    startLine: row[Schema.TsChunks.startLine],
                    endLine: row[Schema.TsChunks.endLine],
                    text: row[Schema.TsChunks.text],
                    symbolPath: row[Schema.TsChunks.symbolPath],
                    kind: SymbolMetaType(rawValue: row[Schema.TsChunks.kind]) ?? .other,
                    embedding: row[Schema.TsChunks.embedding]
                )
            }
        }
    }

    // MARK: - Assembly

    /// Assembles the cached `files` and the Ranker `index` into a
    /// `SearchCorpusSnapshot`: flattens every file's chunk metadata into one
    /// id-ordered sequence (so `chunkIDs` match a from-scratch load's `ORDER
    /// BY id`), joins each chunk back to the index's per-row retrieval state
    /// (its `RankedDocument`, text, and decoded embedding) by id, and repacks
    /// the contiguous cosine matrix from the index's already-decoded vectors —
    /// a `memcpy`, never a re-decode or re-embed.
    ///
    /// - Parameters:
    ///   - files: the per-file metadata cache — the authority on which chunks
    ///     exist and their result metadata.
    ///   - index: the Ranker retrieval index those chunks index into.
    /// - Returns: the assembled snapshot.
    private func assemble(files: [String: FileEntry], index: RankerIndex) -> SearchCorpusSnapshot {
        let metas = files.values.flatMap(\.chunks).sorted { $0.id < $1.id }

        // The index keeps its rows in add order; the join keys every chunk's
        // metadata back to its `RankedDocument` by id. Every metadata id is a
        // live index row (the splice keeps `files` and `index` in lockstep),
        // so this lookup never misses.
        let documentByID = Dictionary(uniqueKeysWithValues: zip(index.ids, index.documents))

        let embeddingDimension = metas.lazy.compactMap { index.embedding(forID: String($0.id))?.count }.first ?? 0

        var embeddingMatrix: [Float] = []
        embeddingMatrix.reserveCapacity(metas.count * embeddingDimension)
        var embeddedFlags: [Bool] = []
        embeddedFlags.reserveCapacity(metas.count)

        for meta in metas {
            Self.appendEmbeddingRow(
                vector: index.embedding(forID: String(meta.id)),
                embeddingDimension: embeddingDimension,
                matrix: &embeddingMatrix,
                embeddedFlags: &embeddedFlags
            )
        }

        return SearchCorpusSnapshot(
            chunkIDs: metas.map(\.id),
            filePaths: metas.map(\.filePath),
            symbolPaths: metas.map(\.symbolPath),
            texts: metas.map { index.block(forID: String($0.id)) ?? "" },
            kinds: metas.map(\.kind),
            startLines: metas.map(\.startLine),
            endLines: metas.map(\.endLine),
            embeddedFlags: embeddedFlags,
            embeddingDimension: embeddingDimension,
            embeddingMatrix: embeddingMatrix,
            rankedDocuments: metas.map { meta in
                guard let document = documentByID[String(meta.id)] else {
                    preconditionFailure(
                        "chunk \(meta.id) has no live index row — `files` and `index` desynced"
                    )
                }
                return document
            }
        )
    }

    /// Appends one chunk's row to `matrix` (and its flag to `embeddedFlags`):
    /// the index's stored vector if present and matching `embeddingDimension`,
    /// or an all-zero row otherwise (which scores an exact `0.0` cosine,
    /// matching `Signals.cosine`'s documented "no embedding" value).
    private static func appendEmbeddingRow(
        vector: [Float]?,
        embeddingDimension: Int,
        matrix: inout [Float],
        embeddedFlags: inout [Bool]
    ) {
        if let vector, embeddingDimension > 0, vector.count == embeddingDimension {
            matrix.append(contentsOf: vector)
            embeddedFlags.append(true)
            return
        }
        matrix.append(contentsOf: [Float](repeating: 0.0, count: embeddingDimension))
        embeddedFlags.append(false)
    }
}
