import Accelerate
import Foundation
import GRDB

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

    /// Each chunk's weighted BM25 term frequency — `symbolPaths[i]`'s tokens
    /// weighted `BM25.symbolPathFieldWeight`, `texts[i]`'s tokens weighted
    /// `BM25.bodyFieldWeight` — positionally aligned with `chunkIds`.
    let weightedTermFrequencies: [[String: Double]]

    /// Each chunk's distinct term set — `Set(weightedTermFrequencies[i].keys)`
    /// — positionally aligned with `chunkIds`. Cached separately so
    /// `BM25Corpus.init(queryTokens:documents:)` doesn't need to rebuild it
    /// from `weightedTermFrequencies` on every query.
    let termSets: [Set<String>]

    /// Each chunk's unweighted token count across both fields, positionally
    /// aligned with `chunkIds` — the `|D|`
    /// `BM25Corpus.score(weightedTermFrequency:documentLength:queryTokens:)`
    /// needs for length normalization.
    let documentLengths: [Int]

    /// Each chunk's canonical trigram set for `symbolPaths[i]`, positionally
    /// aligned with `chunkIds`.
    let symbolPathTrigramSets: [Set<String>]

    /// Each chunk's canonical trigram set for `texts[i]`, positionally
    /// aligned with `chunkIds`.
    let textTrigramSets: [Set<String>]

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
        Self.matvecCosineScores(
            matrix: embeddingMatrix,
            rowCount: chunkCount,
            dimension: embeddingDimension,
            queryVector: queryVector
        )
    }

    /// Computes one dot-product score per row of `matrix` against
    /// `queryVector`, via a single `vDSP_mmul` matrix–vector product — the
    /// Accelerate primitive `cosineScores(queryVector:)` wraps.
    ///
    /// `vDSP_mmul` multiplies `matrix` (treated as `rowCount × dimension`)
    /// by `queryVector` (treated as `dimension × 1`), producing the
    /// `rowCount × 1` result in one call — the vDSP counterpart to
    /// `cblas_sgemv` plan.md calls out for this scoring step, chosen here
    /// over the CBLAS entry point because `cblas_sgemv` is deprecated on
    /// this platform in favor of an ILP64 interface this package doesn't
    /// otherwise need.
    ///
    /// Kept as a standalone, pure function (rather than inlined into
    /// `cosineScores(queryVector:)`) so it can be unit-tested against a
    /// scalar dot-product reference on synthetic fixtures, independent of
    /// loading a real corpus from a `Store`.
    ///
    /// - Parameters:
    ///   - matrix: A row-major `rowCount × dimension` matrix; `matrix.count`
    ///     must equal `rowCount * dimension`.
    ///   - rowCount: The number of rows in `matrix`.
    ///   - dimension: The number of columns in `matrix`, and the required
    ///     length of `queryVector`.
    ///   - queryVector: The vector to score every row of `matrix` against.
    /// - Returns: One score per row, in row order; every score is `0.0` if
    ///   `rowCount` or `dimension` is `0`, or `queryVector.count !=
    ///   dimension`.
    static func matvecCosineScores(matrix: [Float], rowCount: Int, dimension: Int, queryVector: [Float]) -> [Float] {
        guard rowCount > 0, dimension > 0, queryVector.count == dimension else {
            return [Float](repeating: 0.0, count: rowCount)
        }

        var result = [Float](repeating: 0.0, count: rowCount)
        matrix.withUnsafeBufferPointer { matrixBuffer in
            queryVector.withUnsafeBufferPointer { queryBuffer in
                result.withUnsafeMutableBufferPointer { resultBuffer in
                    multiplyMatrixByVector(
                        matrixBuffer: matrixBuffer,
                        queryBuffer: queryBuffer,
                        resultBuffer: resultBuffer,
                        rowCount: rowCount,
                        dimension: dimension
                    )
                }
            }
        }
        return result
    }

    /// Calls `vDSP_mmul` over three already-`withUnsafe(Mutable)BufferPointer`-bound buffers, or
    /// does nothing if any of them has no base address (an empty backing array).
    ///
    /// Factored out of `matvecCosineScores(matrix:rowCount:dimension:queryVector:)`'s triple
    /// nested `withUnsafeBufferPointer` calls so that unavoidable nesting doesn't also have to
    /// carry the pointer-validation `guard` inline, one level deeper still.
    ///
    /// - Parameters:
    ///   - matrixBuffer: The bound buffer over the row-major `rowCount × dimension` matrix.
    ///   - queryBuffer: The bound buffer over the length-`dimension` query vector.
    ///   - resultBuffer: The bound mutable buffer `vDSP_mmul` writes the `rowCount` scores into.
    ///   - rowCount: The number of rows in `matrixBuffer`.
    ///   - dimension: The number of columns in `matrixBuffer`, and the length of `queryBuffer`.
    private static func multiplyMatrixByVector(
        matrixBuffer: UnsafeBufferPointer<Float>,
        queryBuffer: UnsafeBufferPointer<Float>,
        resultBuffer: UnsafeMutableBufferPointer<Float>,
        rowCount: Int,
        dimension: Int
    ) {
        guard
            let matrixBase = matrixBuffer.baseAddress,
            let queryBase = queryBuffer.baseAddress,
            let resultBase = resultBuffer.baseAddress
        else {
            return
        }
        vDSP_mmul(
            matrixBase, 1,
            queryBase, 1,
            resultBase, 1,
            vDSP_Length(rowCount), 1, vDSP_Length(dimension)
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

    /// One row's BM25/trigram precomputation, ready to append to
    /// `SearchCorpusSnapshot`'s parallel arrays.
    ///
    /// Factored out of `build(rows:)`'s per-row loop so that function stays
    /// a thin fold over rows rather than mixing tokenization/BM25/trigram
    /// details with array bookkeeping.
    private struct RowPrecomputation {
        let weightedTermFrequency: [String: Double]
        let termSet: Set<String>
        let documentLength: Int
        let symbolPathTrigramSet: Set<String>
        let textTrigramSet: Set<String>
    }

    /// Tokenizes `row`'s symbol path and body text, builds its BM25
    /// field-weighted term frequency map and term set, and its symbol-path
    /// and body trigram sets.
    ///
    /// - Parameter row: The chunk row to precompute BM25/trigram data for.
    /// - Returns: The precomputed data, ready for `build(rows:)` to append
    ///   into `SearchCorpusSnapshot`'s parallel arrays.
    private static func preprocessRow(row: ChunkRow) -> RowPrecomputation {
        let symbolPathTokens = Tokenizer.tokenize(text: row.symbolPath)
        let bodyTokens = Tokenizer.tokenize(text: row.text)

        var weightedTermFrequency: [String: Double] = [:]
        for token in symbolPathTokens {
            weightedTermFrequency[token, default: 0.0] += BM25.symbolPathFieldWeight
        }
        for token in bodyTokens {
            weightedTermFrequency[token, default: 0.0] += BM25.bodyFieldWeight
        }

        return RowPrecomputation(
            weightedTermFrequency: weightedTermFrequency,
            termSet: Set(weightedTermFrequency.keys),
            documentLength: symbolPathTokens.count + bodyTokens.count,
            symbolPathTrigramSet: Trigram.canonicalTrigramSet(text: row.symbolPath),
            textTrigramSet: Trigram.canonicalTrigramSet(text: row.text)
        )
    }

    /// Folds `rows` into a `SearchCorpusSnapshot`: decodes embeddings into
    /// one contiguous matrix, and precomputes each row's BM25/trigram data.
    private static func build(rows: [ChunkRow]) -> SearchCorpusSnapshot {
        let embeddingDimension = rows.lazy.compactMap { $0.embedding.map { EmbeddingCodec.decode($0).count } }.first ?? 0

        var embeddingMatrix: [Float] = []
        embeddingMatrix.reserveCapacity(rows.count * embeddingDimension)
        var embeddedFlags: [Bool] = []
        embeddedFlags.reserveCapacity(rows.count)

        var weightedTermFrequencies: [[String: Double]] = []
        var termSets: [Set<String>] = []
        var documentLengths: [Int] = []
        var symbolPathTrigramSets: [Set<String>] = []
        var textTrigramSets: [Set<String>] = []
        weightedTermFrequencies.reserveCapacity(rows.count)
        termSets.reserveCapacity(rows.count)
        documentLengths.reserveCapacity(rows.count)
        symbolPathTrigramSets.reserveCapacity(rows.count)
        textTrigramSets.reserveCapacity(rows.count)

        for row in rows {
            appendEmbeddingRow(
                embedding: row.embedding,
                embeddingDimension: embeddingDimension,
                matrix: &embeddingMatrix,
                embeddedFlags: &embeddedFlags
            )

            let precomputed = preprocessRow(row: row)
            weightedTermFrequencies.append(precomputed.weightedTermFrequency)
            termSets.append(precomputed.termSet)
            documentLengths.append(precomputed.documentLength)
            symbolPathTrigramSets.append(precomputed.symbolPathTrigramSet)
            textTrigramSets.append(precomputed.textTrigramSet)
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
            weightedTermFrequencies: weightedTermFrequencies,
            termSets: termSets,
            documentLengths: documentLengths,
            symbolPathTrigramSets: symbolPathTrigramSets,
            textTrigramSets: textTrigramSets
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
