import Foundation
import FoundationModelsRanker

/// The relative weight of each ranking signal
/// `SearchCode.run(corpus:embedder:query:topK:weights:)` fuses via
/// `RRF.fuse(rankedLists:weights:k:)`.
///
/// A weight of `0.0` excludes that signal from the fused ranking entirely —
/// its ranked list is left out of `RRF.fuse`'s inputs altogether, rather than
/// included with a zero weight, so `RRF.normalize(fused:weights:k:)`'s
/// ceiling never counts a signal no chunk could actually score against (see
/// `SearchCode.fuseRankings`).
public struct SearchWeights: Sendable, Equatable {
    /// The weight applied to the BM25 keyword-ranking signal.
    public let bm25: Double

    /// The weight applied to the trigram fuzzy-ranking signal.
    public let trigram: Double

    /// The weight applied to the cosine semantic-ranking signal.
    public let cosine: Double

    /// Equal weight (`1.0`) for every signal.
    public static let `default` = SearchWeights(bm25: 1.0, trigram: 1.0, cosine: 1.0)

    /// Creates a set of per-signal ranking weights.
    ///
    /// - Parameters:
    ///   - bm25: The weight applied to the BM25 keyword-ranking signal.
    ///     Defaults to `1.0`.
    ///   - trigram: The weight applied to the trigram fuzzy-ranking signal.
    ///     Defaults to `1.0`.
    ///   - cosine: The weight applied to the cosine semantic-ranking signal.
    ///     Defaults to `1.0`.
    public init(bm25: Double = 1.0, trigram: Double = 1.0, cosine: Double = 1.0) {
        self.bm25 = bm25
        self.trigram = trigram
        self.cosine = cosine
    }
}

/// A note that `SearchCode.run(corpus:embedder:query:topK:weights:)`'s
/// ranking ran with an incomplete (or entirely absent) embedding layer,
/// attached to `SearchCodeResult` instead of failing the search.
///
/// Present whenever `embeddedChunks < totalChunks` — including the "no
/// embedder at all" and "no chunks indexed yet" cases, both of which have
/// `embeddedChunks == 0` — and `nil` once every indexed chunk is embedded.
/// See plan.md "Search": "No embeddings at all → keyword-only results plus
/// an `IndexingProgress` note, same graceful degradation as Rust."
public struct IndexingProgress: Sendable, Equatable {
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

/// One `SearchCode.run(corpus:embedder:query:topK:weights:)` result: a fused
/// `Hit` plus the `ts_chunks` metadata needed to locate and display it.
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

/// The result of a `SearchCode.run(corpus:embedder:query:topK:weights:)`
/// call.
public struct SearchCodeResult: Sendable, Equatable {
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

/// Hybrid keyword + semantic code search over a workspace's `ts_chunks`.
///
/// Port of the Rust `swissarmyhammer-search` crate's top-level search entry
/// point, fusing three independent rankings — BM25 keyword, trigram fuzzy,
/// cosine semantic — with `RRF.fuse(rankedLists:weights:k:)` (see plan.md
/// "Search"). Chunk data and the cosine matrix live in a `SearchCorpus`,
/// meant to be reused across calls so the tokenize/trigram precomputation in
/// `SearchCorpus.build(rows:)` happens once per corpus generation, not once
/// per query.
public enum SearchCode {
    /// Searches `corpus` for `query`, fusing BM25, trigram, and (when
    /// available) cosine rankings via Reciprocal Rank Fusion.
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
    /// - Parameters:
    ///   - corpus: The workspace's chunk/embedding cache to search.
    ///   - embedder: The embedder to embed `query` with for the cosine
    ///     signal, or `nil` to skip semantic ranking entirely.
    ///   - query: The search query, used for all three signals.
    ///   - topK: The maximum number of hits to return. Defaults to 20.
    ///   - weights: The per-signal fusion weights. Defaults to
    ///     `SearchWeights.default`.
    /// - Returns: The fused, `[0, 1]`-normalized hits (capped at `topK`),
    ///   plus an `IndexingProgress` note whenever the embedding layer is
    ///   incomplete.
    /// - Throws: Rethrows `Store`'s storage errors (via `corpus.snapshot()`).
    public static func run(
        corpus: SearchCorpus,
        embedder: TextEmbedding?,
        query: String,
        topK: Int = 20,
        weights: SearchWeights = .default
    ) async throws -> SearchCodeResult {
        let snapshot = try await corpus.snapshot()

        let (bm25Ranking, bm25Scores) = computeBM25Ranking(snapshot: snapshot, query: query)
        let (trigramRanking, trigramScores) = computeTrigramRanking(snapshot: snapshot, query: query)
        let (cosineRanking, cosineScores) = await computeCosineRanking(snapshot: snapshot, embedder: embedder, query: query)

        let hits = fuseRankings(
            snapshot: snapshot,
            bm25Ranking: bm25Ranking,
            bm25Scores: bm25Scores,
            trigramRanking: trigramRanking,
            trigramScores: trigramScores,
            cosineRanking: cosineRanking,
            cosineScores: cosineScores,
            weights: weights,
            topK: topK
        )

        return SearchCodeResult(
            query: query,
            hits: hits,
            indexingProgress: buildIndexingProgress(snapshot: snapshot, embedderAvailable: embedder != nil)
        )
    }

    // MARK: - Per-signal ranking

    /// Computes the BM25 keyword-ranking signal: `query`'s tokens scored
    /// against every chunk's precomputed weighted term frequency.
    ///
    /// - Returns: The matching chunk indices ranked descending by score (see
    ///   `rankingOfPositiveScores(scores:)`), and the full-length, positionally
    ///   aligned raw score for every chunk.
    private static func computeBM25Ranking(snapshot: SearchCorpusSnapshot, query: String) -> (ranking: [Int], scores: [Double]) {
        let queryTokens = Tokenizer.tokenize(text: query)
        guard snapshot.chunkCount > 0, !queryTokens.isEmpty else {
            return ([], [Double](repeating: 0.0, count: snapshot.chunkCount))
        }

        let corpus = BM25Corpus(
            queryTokens: queryTokens,
            documents: snapshot.rankedDocuments.lazy.map { ($0.documentLength, $0.termSet) }
        )
        let scores = snapshot.rankedDocuments.map { document in
            corpus.score(
                weightedTermFrequency: document.weightedTermFrequency,
                documentLength: document.documentLength,
                queryTokens: queryTokens
            )
        }
        return (rankingOfPositiveScores(scores: scores), scores)
    }

    /// Computes the trigram fuzzy-ranking signal: `query`'s canonical
    /// trigram set scored against each chunk's `symbolPath` (the primary
    /// field, weighted `BM25.primaryFieldWeight`) and `text` (the body
    /// field, weighted `BM25.bodyFieldWeight`) trigram sets.
    ///
    /// - Returns: The matching chunk indices ranked descending by score (see
    ///   `rankingOfPositiveScores(scores:)`), and the full-length, positionally
    ///   aligned raw score for every chunk.
    private static func computeTrigramRanking(snapshot: SearchCorpusSnapshot, query: String) -> (ranking: [Int], scores: [Double]) {
        guard snapshot.chunkCount > 0 else {
            return ([], [])
        }

        let querySet = Trigram.canonicalTrigramSet(text: query)
        let scores = snapshot.rankedDocuments.map { document in
            BM25.primaryFieldWeight * Trigram.dice(querySet: querySet, targetSet: document.primaryTrigramSet)
                + BM25.bodyFieldWeight * Trigram.dice(querySet: querySet, targetSet: document.bodyTrigramSet)
        }
        return (rankingOfPositiveScores(scores: scores), scores)
    }

    /// Computes the cosine semantic-ranking signal by embedding `query` with
    /// `embedder` and scoring it against `snapshot`'s embedding matrix.
    ///
    /// Returns an empty ranking (but a full-length, all-zero `scores` array)
    /// whenever `embedder` is `nil`, no chunk in `snapshot` has an embedding
    /// yet, or embedding `query` itself fails — each of those is graceful
    /// degradation to keyword-only ranking, not an error.
    ///
    /// - Returns: The embedded chunk indices ranked descending by cosine
    ///   score, and the full-length, positionally aligned raw score for
    ///   every chunk (`0.0` for an un-embedded chunk, matching
    ///   `Signals.cosine`'s documented "no embedding" value).
    private static func computeCosineRanking(
        snapshot: SearchCorpusSnapshot,
        embedder: TextEmbedding?,
        query: String
    ) async -> (ranking: [Int], scores: [Double]) {
        let zeroScores = [Double](repeating: 0.0, count: snapshot.chunkCount)
        guard let embedder, snapshot.embeddedChunkCount > 0 else {
            return ([], zeroScores)
        }
        guard let queryVector = await embedQuery(embedder: embedder, query: query) else {
            return ([], zeroScores)
        }

        let scores = snapshot.cosineScores(queryVector: queryVector).map(Double.init)
        let ranking = snapshot.chunkIDs.indices
            .filter { snapshot.embeddedFlags[$0] }
            .sorted { scores[$0] > scores[$1] }
        return (ranking, scores)
    }

    /// Embeds `query` with `embedder`, or `nil` if embedding fails or
    /// returns no vector.
    private static func embedQuery(embedder: TextEmbedding, query: String) async -> [Float]? {
        do {
            return try await embedder.embed([query]).first
        } catch {
            Log.search.warning("query embedding failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The indices of every positive score, descending by score — the
    /// "graceful degradation, no zero-fill" ranked-list shape
    /// `RRF.fuse(rankedLists:weights:k:)` expects: a chunk that scored `0.0`
    /// (no match at all for this signal) is simply absent from the list,
    /// exactly as if it weren't in the corpus for this signal.
    private static func rankingOfPositiveScores(scores: [Double]) -> [Int] {
        scores.indices.filter { scores[$0] > 0.0 }.sorted { scores[$0] > scores[$1] }
    }

    // MARK: - Fusion

    /// Fuses the three per-signal rankings via `RRF.fuse(rankedLists:weights:k:)`,
    /// normalizes to `[0, 1]` via `RRF.normalize(fused:weights:k:)`, and
    /// builds the ordered `SearchCodeMatch` list capped at `topK`.
    private static func fuseRankings(
        snapshot: SearchCorpusSnapshot,
        bm25Ranking: [Int],
        bm25Scores: [Double],
        trigramRanking: [Int],
        trigramScores: [Double],
        cosineRanking: [Int],
        cosineScores: [Double],
        weights: SearchWeights,
        topK: Int
    ) -> [SearchCodeMatch] {
        // One (ranking, weight) pair per signal — a data-driven loop below
        // rather than three hand-maintained if-blocks, so adding a fourth
        // signal later is a one-line addition here, not three parallel
        // arms that must stay in lockstep.
        let signals: [(ranking: [Int], weight: Double)] = [
            (bm25Ranking, weights.bm25),
            (trigramRanking, weights.trigram),
            (cosineRanking, weights.cosine),
        ]

        var rankedLists: [[Int]] = []
        var listWeights: [Double] = []
        // Only signals with a positive configured weight AND at least one
        // matching chunk enter RRF.fuse/normalize's inputs: an empty list
        // would contribute nothing to `fuse` regardless, but leaving its
        // weight out of `normalize`'s ceiling too keeps a perfect
        // keyword-only match normalizing to 1.0 instead of being capped
        // below it by an unreachable cosine share.
        for (ranking, weight) in signals where weight > 0.0 && !ranking.isEmpty {
            rankedLists.append(ranking)
            listWeights.append(weight)
        }

        let fused = RRF.fuse(rankedLists: rankedLists, weights: listWeights)
        let normalized = RRF.normalize(fused: fused, weights: listWeights)

        let orderedChunkIndices = normalized.keys.sorted { leftIndex, rightIndex in
            let leftScore = normalized[leftIndex] ?? 0.0
            let rightScore = normalized[rightIndex] ?? 0.0
            guard leftScore != rightScore else {
                // Deterministic tie-break: lower chunk id first.
                return snapshot.chunkIDs[leftIndex] < snapshot.chunkIDs[rightIndex]
            }
            return leftScore > rightScore
        }

        return orderedChunkIndices.prefix(topK).map { chunkIndex in
            SearchCodeMatch(
                hit: Hit(
                    id: String(snapshot.chunkIDs[chunkIndex]),
                    score: normalized[chunkIndex] ?? 0.0,
                    signals: Signals(
                        bm25: bm25Scores[chunkIndex],
                        trigram: trigramScores[chunkIndex],
                        cosine: cosineScores[chunkIndex]
                    )
                ),
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
