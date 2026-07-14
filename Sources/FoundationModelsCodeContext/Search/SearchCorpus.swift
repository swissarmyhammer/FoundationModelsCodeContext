import Foundation
import GRDB
import RankKit

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
    public let chunkIds: [Int64]

    /// Each chunk's file path, positionally aligned with `chunkIds`.
    public let filePaths: [String]

    /// Each chunk's qualified symbol path, positionally aligned with
    /// `chunkIds`.
    public let symbolPaths: [String]

    /// Each chunk's full source text, positionally aligned with `chunkIds`.
    public let texts: [String]

    /// Each chunk's meta-type, positionally aligned with `chunkIds`.
    public let kinds: [SymbolMetaType]

    /// Each chunk's zero-based start line, positionally aligned with
    /// `chunkIds`.
    public let startLines: [Int]

    /// Each chunk's zero-based end line, positionally aligned with
    /// `chunkIds`.
    public let endLines: [Int]

    /// Whether each chunk carries a usable (non-`NULL`,
    /// `embeddingDimension`-length) embedding, positionally aligned with
    /// `chunkIds`. A chunk without one contributes an all-zero row to
    /// `embeddingMatrix`, which — since every real embedding is
    /// L2-normalized — scores an exact `0.0` cosine against any query,
    /// matching `Signals.cosine`'s documented "no embedding" value.
    public let embeddedFlags: [Bool]

    /// The dimension of every row in `embeddingMatrix`; `0` if no chunk in
    /// the corpus has an embedding yet.
    public let embeddingDimension: Int

    /// The corpus's embeddings as one contiguous, row-major `chunkCount ×
    /// embeddingDimension` matrix — row `i` is `chunkIds[i]`'s embedding (or
    /// an all-zero row if `embeddedFlags[i]` is `false`). Not `public`:
    /// `cosineScores(queryVector:)` is the sanctioned way to score it.
    let embeddingMatrix: [Float]

    /// Each chunk's precomputed BM25/trigram statistics — `symbolPaths[i]`
    /// as the primary field (weighted `BM25.primaryFieldWeight`), `texts[i]`
    /// as the body field (weighted `BM25.bodyFieldWeight`) — positionally
    /// aligned with `chunkIds`. `RankKit.RankedDocument` carries the
    /// weighted term frequency, term set, document length, and both trigram
    /// sets the BM25/trigram scoring stages consume.
    let rankedDocuments: [RankedDocument]

    /// The number of chunks in this snapshot.
    public var chunkCount: Int { chunkIds.count }

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
    /// - Returns: One score per chunk, positionally aligned with `chunkIds`;
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

/// Owns one workspace's lazily-loaded, generation-invalidated
/// `SearchCorpusSnapshot` cache.
///
/// See plan.md "Search", "Where the cosines happen": a `SearchCorpus` is
/// meant to be created once (e.g. by `CodeContext`) and reused across every
/// `SearchCode.run(corpus:embedder:query:topK:weights:)` call.
/// `snapshot()` reloads from `store` only when `store.generation` has
/// advanced past the generation the cached snapshot was built at, so a file
/// that finishes indexing shows up on the very next call — no explicit
/// invalidation call, no process restart.
public actor SearchCorpus {
    private let store: Store
    private var cached: (generation: Int, snapshot: SearchCorpusSnapshot)?

    /// Creates a corpus cache over `store`, with no snapshot loaded yet —
    /// the first `snapshot()` call performs the initial load.
    ///
    /// - Parameter store: The workspace's index store `snapshot()` loads
    ///   `ts_chunks` from.
    public init(store: Store) {
        self.store = store
    }

    /// Returns the current corpus snapshot, reloading from `store` if it has
    /// written since the cached snapshot (if any) was built.
    ///
    /// - Returns: The up-to-date snapshot.
    /// - Throws: Rethrows `Store`'s storage errors.
    public func snapshot() async throws -> SearchCorpusSnapshot {
        let currentGeneration = store.generation
        if let cached, cached.generation == currentGeneration {
            return cached.snapshot
        }

        let loaded = try await Self.load(store: store)
        cached = (currentGeneration, loaded)
        return loaded
    }

    // MARK: - Loading

    /// One `ts_chunks` row as loaded from disk, before it's folded into a
    /// `SearchCorpusSnapshot`'s parallel arrays.
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

    /// Loads every `ts_chunks` row and builds a fresh `SearchCorpusSnapshot`
    /// from them.
    private static func load(store: Store) async throws -> SearchCorpusSnapshot {
        let rows: [ChunkRow] = try await store.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT \(Schema.TsChunks.id), \(Schema.TsChunks.filePath), \(Schema.TsChunks.startLine), \
                       \(Schema.TsChunks.endLine), \(Schema.TsChunks.text), \(Schema.TsChunks.symbolPath), \
                       \(Schema.TsChunks.kind), \(Schema.TsChunks.embedding) \
                FROM \(Schema.TsChunks.table) ORDER BY \(Schema.TsChunks.id)
                """
            ).map { row in
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
        return build(rows: rows)
    }

    /// Folds `rows` into a `SearchCorpusSnapshot`: decodes embeddings into
    /// one contiguous matrix, and precomputes each row's BM25/trigram data
    /// as a `RankKit.RankedDocument` (symbol path as the primary field, body
    /// text as the body field).
    private static func build(rows: [ChunkRow]) -> SearchCorpusSnapshot {
        let embeddingDimension = rows.lazy.compactMap { $0.embedding.map { EmbeddingCodec.decode($0).count } }.first ?? 0

        var embeddingMatrix: [Float] = []
        embeddingMatrix.reserveCapacity(rows.count * embeddingDimension)
        var embeddedFlags: [Bool] = []
        embeddedFlags.reserveCapacity(rows.count)

        for row in rows {
            appendEmbeddingRow(
                embedding: row.embedding,
                embeddingDimension: embeddingDimension,
                matrix: &embeddingMatrix,
                embeddedFlags: &embeddedFlags
            )
        }

        return SearchCorpusSnapshot(
            chunkIds: rows.map(\.id),
            filePaths: rows.map(\.filePath),
            symbolPaths: rows.map(\.symbolPath),
            texts: rows.map(\.text),
            kinds: rows.map(\.kind),
            startLines: rows.map(\.startLine),
            endLines: rows.map(\.endLine),
            embeddedFlags: embeddedFlags,
            embeddingDimension: embeddingDimension,
            embeddingMatrix: embeddingMatrix,
            rankedDocuments: rows.map { RankedDocument(primaryText: $0.symbolPath, bodyText: $0.text) }
        )
    }

    /// Appends one row to `matrix` (and its flag to `embeddedFlags`): the
    /// decoded embedding if `embedding` is present and matches
    /// `embeddingDimension`, or an all-zero row otherwise.
    private static func appendEmbeddingRow(
        embedding: Data?,
        embeddingDimension: Int,
        matrix: inout [Float],
        embeddedFlags: inout [Bool]
    ) {
        if let embedding, embeddingDimension > 0 {
            let vector = EmbeddingCodec.decode(embedding)
            if vector.count == embeddingDimension {
                matrix.append(contentsOf: vector)
                embeddedFlags.append(true)
                return
            }
        }
        matrix.append(contentsOf: [Float](repeating: 0.0, count: embeddingDimension))
        embeddedFlags.append(false)
    }
}
