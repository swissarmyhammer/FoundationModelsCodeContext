import Foundation
import FoundationModelsExtras
import FoundationModelsRanker
import Tracing

/// A note that `SearchCode.run(corpus:embedder:selection:query:topK:weights:tracer:)`'s
/// ranking ran with an incomplete (or entirely absent) embedding layer,
/// attached to `SearchCodeResult` instead of failing the search.
///
/// Present whenever `embeddedChunks < totalChunks` — including the "no
/// embedder at all" and "no chunks indexed yet" cases, both of which have
/// `embeddedChunks == 0` — and `nil` once every indexed chunk is embedded.
/// See plan.md "Search": "No embeddings at all → keyword-only results plus
/// an `IndexingProgress` note, same graceful degradation as Rust."
///
/// The JSON keys are the property names.
public struct IndexingProgress: Sendable, Equatable, Encodable {
    /// The total number of chunks in the corpus at the time of this search.
    public let totalChunks: Int

    /// The number of those chunks that carry a usable embedding.
    public let embeddedChunks: Int

    /// A human-readable explanation of why embeddings are incomplete.
    public let note: String

    /// Creates an indexing-progress note.
    ///
    /// - Parameters:
    ///   - totalChunks: The total number of chunks in the corpus.
    ///   - embeddedChunks: The number of those chunks that carry a usable
    ///     embedding.
    ///   - note: A human-readable explanation of why embeddings are
    ///     incomplete.
    public init(totalChunks: Int, embeddedChunks: Int, note: String) {
        self.totalChunks = totalChunks
        self.embeddedChunks = embeddedChunks
        self.note = note
    }
}

/// One `SearchCode.run(corpus:embedder:selection:query:topK:weights:tracer:)` result: a fused
/// `Hit` plus the `ts_chunks` metadata needed to locate and display it.
///
/// The JSON form comes from a custom `encode(to:)`, because the Ranker `Hit`
/// type is not `Encodable`. The `hit` key holds an object with the `id`
/// string, the `score` number and a `signals` object. The `signals` object
/// holds the `bm25`, `trigram` and `cosine` numbers. All other keys are the
/// property names, and `kind` is the `SymbolMetaType` raw value.
public struct SearchCodeMatch: Sendable, Equatable {
    /// The fused score and per-signal `Signals` for this chunk.
    public let hit: Hit

    /// The path of the file containing this chunk.
    public let filePath: String

    /// The chunk's qualified symbol path.
    public let symbolPath: String

    /// The chunk's meta-type.
    public let kind: SymbolMetaType

    /// The chunk's zero-based start line.
    public let startLine: Int

    /// The chunk's zero-based end line.
    public let endLine: Int

    /// The chunk's full source text.
    public let text: String

    /// Creates a search-code match.
    ///
    /// - Parameters:
    ///   - hit: The fused score and per-signal `Signals` for this chunk.
    ///   - filePath: The path of the file containing this chunk.
    ///   - symbolPath: The chunk's qualified symbol path.
    ///   - kind: The chunk's meta-type.
    ///   - startLine: The chunk's zero-based start line.
    ///   - endLine: The chunk's zero-based end line.
    ///   - text: The chunk's full source text.
    public init(
        hit: Hit,
        filePath: String,
        symbolPath: String,
        kind: SymbolMetaType,
        startLine: Int,
        endLine: Int,
        text: String
    ) {
        self.hit = hit
        self.filePath = filePath
        self.symbolPath = symbolPath
        self.kind = kind
        self.startLine = startLine
        self.endLine = endLine
        self.text = text
    }
}

extension SearchCodeMatch: Encodable {
    /// The JSON keys of a search-code match. Each key is a property name.
    private enum CodingKeys: String, CodingKey {
        case hit
        case filePath
        case symbolPath
        case kind
        case startLine
        case endLine
        case text
    }

    /// The JSON keys of the `hit` object. Each key is a `Hit` property name.
    private enum HitCodingKeys: String, CodingKey {
        case id
        case score
        case signals
    }

    /// The JSON keys of the `signals` object in the `hit` object. Each key is
    /// a `Signals` property name.
    private enum SignalsCodingKeys: String, CodingKey {
        case bm25
        case trigram
        case cosine
    }

    /// Encodes this match in the JSON form that the type documentation
    /// gives.
    ///
    /// - Parameter encoder: The encoder that receives the JSON object.
    /// - Throws: An `EncodingError` when the encoder cannot write a value.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var hitContainer = container.nestedContainer(keyedBy: HitCodingKeys.self, forKey: .hit)
        try encodeHit(into: &hitContainer)
        try container.encode(filePath, forKey: .filePath)
        try container.encode(symbolPath, forKey: .symbolPath)
        try container.encode(kind, forKey: .kind)
        try container.encode(startLine, forKey: .startLine)
        try container.encode(endLine, forKey: .endLine)
        try container.encode(text, forKey: .text)
    }

    /// Encodes the `id`, the `score` and the `signals` of `hit` as plain
    /// values.
    ///
    /// - Parameter container: The container of the `hit` object.
    /// - Throws: An `EncodingError` when the encoder cannot write a value.
    private func encodeHit(into container: inout KeyedEncodingContainer<HitCodingKeys>) throws {
        try container.encode(hit.id, forKey: .id)
        try container.encode(hit.score, forKey: .score)
        var signalsContainer = container.nestedContainer(keyedBy: SignalsCodingKeys.self, forKey: .signals)
        try signalsContainer.encode(hit.signals.bm25, forKey: .bm25)
        try signalsContainer.encode(hit.signals.trigram, forKey: .trigram)
        try signalsContainer.encode(hit.signals.cosine, forKey: .cosine)
    }
}

/// The result of a `SearchCode.run(corpus:embedder:selection:query:topK:weights:tracer:)`
/// call.
///
/// The JSON keys are the property names. When `indexingProgress` is `nil`,
/// the JSON does not include the `indexingProgress` key.
public struct SearchCodeResult: Sendable, Equatable, Encodable {
    /// The original query string.
    public let query: String

    /// Matches ordered by descending fused score, capped at `topK`.
    public let hits: [SearchCodeMatch]

    /// Set whenever the corpus's embedding layer is incomplete (or entirely
    /// absent), so cosine ranking was skipped or partial; `nil` once every
    /// chunk is embedded.
    public let indexingProgress: IndexingProgress?

    /// Creates a search-code result.
    ///
    /// - Parameters:
    ///   - query: The original query string.
    ///   - hits: Matches ordered by descending fused score.
    ///   - indexingProgress: Set whenever the embedding layer is incomplete;
    ///     `nil` otherwise.
    public init(query: String, hits: [SearchCodeMatch], indexingProgress: IndexingProgress?) {
        self.query = query
        self.hits = hits
        self.indexingProgress = indexingProgress
    }
}

/// Hybrid keyword + semantic code search over a workspace's `ts_chunks`, then selection by a
/// model.
///
/// Port of the Rust `swissarmyhammer-search` crate's top-level search entry
/// point, fusing three independent rankings — BM25 keyword, trigram fuzzy,
/// cosine semantic — with `HybridRanker.topMatches(ids:documents:query:cosineScores:weights:limit:)`
/// of FoundationModelsRanker (see plan.md "Search"). Chunk data and the cosine matrix live in a `SearchCorpus`,
/// meant to be reused across calls so the tokenize/trigram precomputation in
/// `SearchCorpus.build(rows:)` happens once per corpus generation, not once
/// per query.
///
/// A search has two steps. `retrieve(corpus:embedder:query:topK:weights:tracer:)` ranks the
/// chunks. `run(corpus:embedder:selection:query:topK:weights:tracer:)` then lets the selection
/// model of the host pick and order the retrieval hits.
public enum SearchCode {
    /// Searches `corpus` for `query` with retrieval, and lets the selection model pick and order
    /// the retrieval hits.
    ///
    /// Retrieval gives at most `topK` candidates (see
    /// `retrieve(corpus:embedder:query:topK:weights:tracer:)`). `selection` makes the selection
    /// configuration from the ids of the candidates, one time. A `SelectionTier` over a catalog of
    /// the candidates then asks the model to pick the candidates that serve `query`. The
    /// candidate ids are the ids of the hits. The summary of a candidate is its symbol path with
    /// the kind and the file, and its block is the verbatim chunk text.
    ///
    /// The result holds the selected hits in the order of the model, at most `topK`. Each hit keeps
    /// its own retrieval score and its own signals. There is no fallback: an error of `selection`
    /// or of the selection session is the error of this call.
    ///
    /// - Parameters:
    ///   - corpus: The workspace's chunk/embedding cache to search.
    ///   - embedder: The embedder to embed `query` with for the cosine signal, or `nil` to skip
    ///     semantic ranking entirely.
    ///   - selection: Makes the selection configuration from the ids of the candidates. A search
    ///     with no candidate does not call it.
    ///   - query: The search query. It is the request that the selection model reads.
    ///   - topK: The maximum number of candidates, and of hits. Defaults to 20.
    ///   - weights: The per-signal fusion weights of retrieval. Defaults to `SignalWeights()`,
    ///     equal weight for every signal.
    ///   - tracer: The tracer of the search span, of the select span and of the embed span of the
    ///     query. Defaults to `nil`, which reads the bootstrapped tracer at the time of the call.
    /// - Returns: The selected hits, plus an `IndexingProgress` note whenever the embedding layer
    ///   is incomplete.
    /// - Throws: Rethrows `Store`'s storage errors (via `corpus.snapshot()`), what `selection`
    ///   throws, and what the selection session throws.
    ///
    /// The call runs in one `CodeContextTracing.SpanName.search` span. It holds `topK`, and the
    /// number of hits that the call returns, after the selection. The selection step is a child
    /// span (`CodeContextTracing.SpanName.select`). Neither span holds the query.
    public static func run(
        corpus: SearchCorpus,
        embedder: PooledEmbedding?,
        selection: SelectionFactory,
        query: String,
        topK: Int = CodeContextDefaults.searchTopK,
        weights: SignalWeights = CodeContextDefaults.searchWeights,
        tracer: (any Tracer)? = nil
    ) async throws -> SearchCodeResult {
        try await CodeContextSpans.withSearchSpan(
            CodeContextTracing.SpanName.search,
            tracer: tracer,
            limit: topK,
            resultCount: \.hits.count
        ) {
            let retrieved = try await retrieve(
                corpus: corpus, embedder: embedder, query: query, topK: topK, weights: weights, tracer: tracer
            )
            let candidates = retrieved.hits.map { match in
                match.selectionCandidate(id: match.hit.id, payload: match)
            }
            let selected = try await CodeSelection.select(
                candidates, query: query, limit: topK, factory: selection, tracer: tracer
            )
            return SearchCodeResult(query: query, hits: selected, indexingProgress: retrieved.indexingProgress)
        }
    }

    /// Searches `corpus` for `query`, fusing BM25, trigram, and (when
    /// available) cosine rankings through `HybridRanker`. No model runs.
    ///
    /// `embedder` embeds `query` itself for the cosine signal; it is
    /// independent of whatever embedder (if any) originally embedded the
    /// corpus's chunks. The cosine signal is skipped entirely — falling back
    /// to keyword-only (BM25 + trigram) ranking — whenever `embedder` is
    /// `nil`, embedding the query fails, or no chunk in the corpus has an
    /// embedding yet; `SearchCodeResult.indexingProgress` is non-`nil` in
    /// every one of those cases, and also whenever some (but not all)
    /// chunks are embedded.
    ///
    /// This is the retrieval step of `run(corpus:embedder:selection:query:topK:weights:tracer:)`.
    /// A manager uses it for each root, and runs one selection over the merged candidates.
    ///
    /// - Parameters:
    ///   - corpus: The workspace's chunk/embedding cache to search.
    ///   - embedder: The embedder to embed `query` with for the cosine
    ///     signal, or `nil` to skip semantic ranking entirely.
    ///   - query: The search query, used for all three signals.
    ///   - topK: The maximum number of hits to return. Defaults to 20.
    ///   - weights: The per-signal fusion weights. Defaults to
    ///     `SignalWeights()`, equal weight for every
    ///     signal.
    ///   - tracer: The tracer of the embed span of the query. Defaults to `nil`,
    ///     which reads the bootstrapped tracer at the time of the call.
    /// - Returns: The fused, `[0, 1]`-normalized hits (capped at `topK`),
    ///   plus an `IndexingProgress` note whenever the embedding layer is
    ///   incomplete.
    /// - Throws: Rethrows `Store`'s storage errors (via `corpus.snapshot()`).
    ///
    /// The retrieval opens no search span: the caller owns the one
    /// `CodeContextTracing.SpanName.search` span of the search call, which covers the retrieval
    /// and the selection. The embed call of the query is a child span of the span that is open in
    /// the caller.
    internal static func retrieve(
        corpus: SearchCorpus,
        embedder: PooledEmbedding?,
        query: String,
        topK: Int = CodeContextDefaults.searchTopK,
        weights: SignalWeights = CodeContextDefaults.searchWeights,
        tracer: (any Tracer)? = nil
    ) async throws -> SearchCodeResult {
        let snapshot = try await corpus.snapshot()
        let cosineScores = await queryCosineScores(snapshot: snapshot, embedder: embedder, query: query, tracer: tracer)
        let hits = rank(snapshot: snapshot, query: query, cosineScores: cosineScores, weights: weights, topK: topK)

        return SearchCodeResult(
            query: query,
            hits: hits,
            indexingProgress: buildIndexingProgress(snapshot: snapshot, embedderAvailable: embedder != nil)
        )
    }

    // MARK: - Cosine signal

    /// Scores every chunk of `snapshot` against the embedding of `query`.
    ///
    /// Returns `nil` — no cosine signal, so keyword-only ranking — whenever `embedder` is
    /// `nil`, no chunk in `snapshot` has an embedding yet, or embedding `query` fails. Each of
    /// those is graceful degradation, not an error.
    ///
    /// - Returns: One score per chunk, positionally aligned with `snapshot.chunkIDs`; `nil`
    ///   for a chunk without an embedding (see `SearchCorpusSnapshot.cosineScores(queryVector:)`).
    private static func queryCosineScores(
        snapshot: SearchCorpusSnapshot,
        embedder: PooledEmbedding?,
        query: String,
        tracer: (any Tracer)?
    ) async -> [Double?]? {
        guard let embedder, snapshot.embeddedChunkCount > 0 else {
            return nil
        }
        guard let queryVector = await embedQuery(embedder: embedder, query: query, tracer: tracer) else {
            return nil
        }
        return snapshot.cosineScores(queryVector: queryVector)
    }

    /// Embeds `query` with `embedder`, or `nil` if embedding fails or
    /// returns no vector.
    ///
    /// The embed call runs in one `CodeContextTracing.SpanName.embed` span
    /// through `tracer`, and writes one "enter" log record.
    private static func embedQuery(embedder: PooledEmbedding, query: String, tracer: (any Tracer)?) async -> [Float]? {
        do {
            return try await CodeContextSpans.embed([query], with: embedder, tracer: tracer).first
        } catch {
            Log.search.warning(
                "the embedder failed for the query; the search uses no similarity signal",
                metadata: [CodeContextTracing.MetadataKey.errorType: Log.errorType(of: error)]
            )
            return nil
        }
    }

    // MARK: - Ranking

    /// Ranks `snapshot` with `HybridRanker.topMatches(ids:documents:query:cosineScores:weights:limit:)`
    /// and builds the ordered `SearchCodeMatch` list capped at `topK`.
    ///
    /// The snapshot arrays are sorted ascending by chunk id (see `SearchCorpus`), and
    /// `HybridRanker` breaks ties by ascending input index, so a tie goes to the lower chunk id.
    private static func rank(
        snapshot: SearchCorpusSnapshot,
        query: String,
        cosineScores: [Double?]?,
        weights: SignalWeights,
        topK: Int
    ) -> [SearchCodeMatch] {
        let ids = snapshot.chunkIDs.map { String($0) }
        let hits = HybridRanker.topMatches(
            ids: ids,
            documents: snapshot.rankedDocuments,
            query: query,
            cosineScores: cosineScores,
            weights: weights,
            limit: topK
        )

        let chunkIndexByID = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        return hits.map { hit in
            guard let chunkIndex = chunkIndexByID[hit.id] else {
                preconditionFailure("HybridRanker returned the id \(hit.id), which is not a chunk id of the snapshot")
            }
            return SearchCodeMatch(
                hit: hit,
                filePath: snapshot.filePaths[chunkIndex],
                symbolPath: snapshot.symbolPaths[chunkIndex],
                kind: snapshot.kinds[chunkIndex],
                startLine: snapshot.startLines[chunkIndex],
                endLine: snapshot.endLines[chunkIndex],
                text: snapshot.texts[chunkIndex]
            )
        }
    }

    // MARK: - IndexingProgress

    /// Builds the `IndexingProgress` note for `snapshot`, or `nil` if every
    /// chunk in it is already embedded.
    private static func buildIndexingProgress(snapshot: SearchCorpusSnapshot, embedderAvailable: Bool) -> IndexingProgress? {
        guard snapshot.chunkCount == 0 || snapshot.embeddedChunkCount < snapshot.chunkCount else {
            return nil
        }
        return IndexingProgress(
            totalChunks: snapshot.chunkCount,
            embeddedChunks: snapshot.embeddedChunkCount,
            note: progressNote(
                embedderAvailable: embedderAvailable,
                embeddedChunks: snapshot.embeddedChunkCount,
                totalChunks: snapshot.chunkCount
            )
        )
    }

    /// The human-readable explanation attached to `IndexingProgress.note`,
    /// for each of the three ways embeddings can be incomplete: no embedder
    /// configured, the corpus has no chunks yet, or some (but not all)
    /// chunks are embedded.
    private static func progressNote(embedderAvailable: Bool, embeddedChunks: Int, totalChunks: Int) -> String {
        guard embedderAvailable else {
            return "no embedder configured; results are keyword-only (BM25 + trigram)"
        }
        guard totalChunks > 0 else {
            return "no chunks indexed yet"
        }
        return "\(embeddedChunks)/\(totalChunks) chunks embedded; semantic ranking may be incomplete"
    }
}
