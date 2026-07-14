import Foundation
import RankKit

/// One chunk's location and text, referenced from a `FindDuplicatesResult`
/// either as a group's source or as one of its duplicate matches.
public struct DuplicateChunkRef: Sendable, Equatable {
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

    /// Creates a duplicate chunk reference.
    ///
    /// - Parameters:
    ///   - filePath: The path of the file containing this chunk.
    ///   - symbolPath: The chunk's qualified symbol path.
    ///   - kind: The chunk's meta-type.
    ///   - startLine: The chunk's zero-based start line.
    ///   - endLine: The chunk's zero-based end line.
    ///   - text: The chunk's full source text.
    public init(filePath: String, symbolPath: String, kind: SymbolMetaType, startLine: Int, endLine: Int, text: String) {
        self.filePath = filePath
        self.symbolPath = symbolPath
        self.kind = kind
        self.startLine = startLine
        self.endLine = endLine
        self.text = text
    }
}

/// One chunk found to be a near-duplicate of a `DuplicateGroup`'s source chunk.
public struct DuplicateMatch: Sendable, Equatable {
    /// The similar chunk found elsewhere in the corpus.
    public let chunk: DuplicateChunkRef

    /// The cosine similarity between this chunk's embedding and the source
    /// chunk's embedding, in `[-1.0, 1.0]` (matching `Signals.cosine`'s
    /// documented range) — in practice always `>=` the `minSimilarity`
    /// threshold that produced this match.
    public let similarity: Double

    /// Creates a duplicate match.
    ///
    /// - Parameters:
    ///   - chunk: The similar chunk found elsewhere in the corpus.
    ///   - similarity: The cosine similarity between this chunk's embedding
    ///     and the source chunk's embedding.
    public init(chunk: DuplicateChunkRef, similarity: Double) {
        self.chunk = chunk
        self.similarity = similarity
    }
}

/// A source chunk and every near-duplicate `FindDuplicatesOps.findDuplicates(corpus:file:minSimilarity:minChunkBytes:maxPerChunk:)`
/// found for it.
public struct DuplicateGroup: Sendable, Equatable {
    /// The chunk every entry in `duplicates` was compared against.
    public let source: DuplicateChunkRef

    /// Chunks found to be near-duplicates of `source`, sorted by descending
    /// similarity and capped at the `maxPerChunk` the search was run with.
    public let duplicates: [DuplicateMatch]

    /// Creates a duplicate group.
    ///
    /// - Parameters:
    ///   - source: The chunk every entry in `duplicates` was compared against.
    ///   - duplicates: Chunks found to be near-duplicates of `source`, sorted
    ///     by descending similarity.
    public init(source: DuplicateChunkRef, duplicates: [DuplicateMatch]) {
        self.source = source
        self.duplicates = duplicates
    }
}

/// Which chunks `FindDuplicatesOps.findDuplicates(corpus:file:minSimilarity:minChunkBytes:maxPerChunk:)`
/// treated as candidate source chunks.
public enum FindDuplicatesScope: Sendable, Equatable {
    /// Every eligible chunk in the corpus was a candidate source.
    case workspace

    /// Only chunks in this file were candidate sources; every eligible chunk
    /// in the corpus (including ones in this same file) was a candidate
    /// duplicate.
    case file(String)
}

/// The result of a `FindDuplicatesOps.findDuplicates(corpus:file:minSimilarity:minChunkBytes:maxPerChunk:)`
/// call.
public struct FindDuplicatesResult: Sendable, Equatable {
    /// Which chunks were treated as candidate source chunks.
    public let scope: FindDuplicatesScope

    /// Groups of duplicates, one per source chunk that has at least one
    /// match, sorted by descending best-match similarity.
    public let groups: [DuplicateGroup]

    /// The number of candidate source chunks considered (after the
    /// `minChunkBytes` size filter and requiring a usable embedding).
    public let sourceChunks: Int

    /// The total number of chunks eligible to be reported as a duplicate
    /// match (after the same size/embedding filter), across every meta-type
    /// partition.
    public let comparedChunks: Int

    /// Creates a find-duplicates result.
    ///
    /// - Parameters:
    ///   - scope: Which chunks were treated as candidate source chunks.
    ///   - groups: Groups of duplicates, one per source chunk that has at
    ///     least one match.
    ///   - sourceChunks: The number of candidate source chunks considered.
    ///   - comparedChunks: The total number of chunks eligible to be
    ///     reported as a duplicate match.
    public init(scope: FindDuplicatesScope, groups: [DuplicateGroup], sourceChunks: Int, comparedChunks: Int) {
        self.scope = scope
        self.groups = groups
        self.sourceChunks = sourceChunks
        self.comparedChunks = comparedChunks
    }
}

/// Meta-type-aware near-duplicate detection over `ts_chunks` embeddings.
///
/// Port of the Rust `swissarmyhammer-code-context::ops::find_duplicates`
/// module (`crates/swissarmyhammer-code-context/src/ops/find_duplicates.rs`),
/// with the meta-type constraint plan.md's "The index" and "`findDuplicates`
/// is meta-type-aware" sections describe: candidate pairs are compared only
/// within their own `SymbolMetaType` partition — free functions and methods
/// share a partition (`.function`/`.method`), type declarations
/// (`.type`) have their own, and every other chunk kind (`.other`) has its
/// own — so a function body is never reported as a duplicate of a class, no
/// matter how similar their embeddings are.
///
/// Reuses `SearchCorpus`'s cached embedding matrix rather than re-scanning
/// `ts_chunks`: each meta-type partition's candidate sub-matrix is gathered
/// once (via `SearchCorpusSnapshot.gatherSubMatrix(rowIndices:)`) and then
/// scored against with one `RankKit.CosineScoring.matvecScores(matrix:rowCount:dimension:queryVector:)`
/// call per source chunk in that partition, so both workspace scope (every
/// eligible chunk in a partition, scored against that one shared sub-matrix)
/// and file scope (only `file`'s eligible chunks as sources, scored against
/// the same shared sub-matrix) share one per-source comparison path — see
/// plan.md "Where the cosines happen": "matrix–matrix product per partition
/// when scoped to the workspace, one matvec per source chunk when scoped to
/// a file" describes the same total FLOP count this shared-sub-matrix,
/// one-matvec-per-source shape achieves, without introducing a second,
/// untested Accelerate primitive alongside the already-tested matvec.
public enum FindDuplicatesOps {
    /// Finds near-duplicate chunks in `corpus`, grouped by source chunk.
    ///
    /// A chunk is eligible to participate (as either a source or a
    /// duplicate) only if it carries a usable embedding and its text is at
    /// least `minChunkBytes` UTF-8 bytes long. Within the eligible set, a
    /// chunk is never reported as its own duplicate (`self-pair`), nor as a
    /// duplicate of another chunk sharing its exact `(filePath, symbolPath)`
    /// identity (`same-symbol pair`) — the latter guards against a
    /// duplicate-indexed row of the very same declaration being reported as
    /// if it were separately duplicated code.
    ///
    /// - Parameters:
    ///   - corpus: The workspace's chunk/embedding cache to search.
    ///   - file: When non-`nil`, only this file's eligible chunks are
    ///     candidate sources (though any eligible chunk in the corpus,
    ///     including ones in this same file, can still appear as a
    ///     duplicate match). `nil` scans the whole workspace. Defaults to
    ///     `nil`.
    ///   - minSimilarity: The minimum cosine similarity, in `[-1.0, 1.0]`,
    ///     for a candidate to be reported as a duplicate. Defaults to `0.85`.
    ///   - minChunkBytes: The minimum chunk text size, in UTF-8 bytes, for a
    ///     chunk to be eligible at all. Defaults to `100`.
    ///   - maxPerChunk: The maximum number of duplicates reported per source
    ///     chunk. Defaults to `5`.
    /// - Returns: One group per source chunk with at least one duplicate,
    ///   sorted by descending best-match similarity.
    /// - Throws: Rethrows `Store`'s storage errors (via `corpus.snapshot()`).
    public static func findDuplicates(
        corpus: SearchCorpus,
        file: String? = nil,
        minSimilarity: Double = 0.85,
        minChunkBytes: Int = 100,
        maxPerChunk: Int = 5
    ) async throws -> FindDuplicatesResult {
        let snapshot = try await corpus.snapshot()
        let eligibleByPartition = eligiblePartitionedIndices(snapshot: snapshot, minChunkBytes: minChunkBytes)
        let sourceIndices = sourceChunkIndices(snapshot: snapshot, eligibleByPartition: eligibleByPartition, file: file)

        let groups = buildGroups(
            snapshot: snapshot,
            sourceIndices: sourceIndices,
            eligibleByPartition: eligibleByPartition,
            minSimilarity: Float(minSimilarity),
            maxPerChunk: maxPerChunk
        )

        return FindDuplicatesResult(
            scope: file.map(FindDuplicatesScope.file) ?? .workspace,
            groups: groups,
            sourceChunks: sourceIndices.count,
            comparedChunks: eligibleByPartition.values.reduce(0) { $0 + $1.count }
        )
    }

    // MARK: - Eligibility and scoping

    /// Every meta-type partition candidate pairs are compared within — see
    /// this type's doc comment.
    private enum Partition: Hashable {
        /// Free functions and instance/static methods.
        case callable

        /// Type declarations.
        case type

        /// Any other embeddable chunk kind.
        case other

        /// The partition `kind` belongs to.
        ///
        /// A `switch`, not a dictionary: this is a closed, four-case mapping
        /// colocated with the type it describes, matching this codebase's
        /// established enum-to-value convention (see `IndexLayer.column`'s
        /// doc comment for the full rationale).
        static func of(kind: SymbolMetaType) -> Partition {
            switch kind {
            case .function, .method:
                return .callable
            case .type:
                return .type
            case .other:
                return .other
            }
        }
    }

    /// Finds every chunk index eligible to participate in comparison (a
    /// usable embedding, and text at least `minChunkBytes` UTF-8 bytes
    /// long), grouped by `Partition`.
    ///
    /// - Parameters:
    ///   - snapshot: The corpus snapshot to scan.
    ///   - minChunkBytes: The minimum chunk text size, in UTF-8 bytes.
    /// - Returns: Eligible chunk indices, grouped by their `Partition`, each
    ///   list in ascending index order.
    private static func eligiblePartitionedIndices(snapshot: SearchCorpusSnapshot, minChunkBytes: Int) -> [Partition: [Int]] {
        let eligible = snapshot.chunkIds.indices.filter { index in
            snapshot.embeddedFlags[index] && snapshot.texts[index].utf8.count >= minChunkBytes
        }
        return Dictionary(grouping: eligible) { Partition.of(kind: snapshot.kinds[$0]) }
    }

    /// Determines the candidate source chunk indices: every eligible chunk
    /// when `file` is `nil`, or only `file`'s eligible chunks otherwise.
    ///
    /// - Parameters:
    ///   - snapshot: The corpus snapshot to scan.
    ///   - eligibleByPartition: The already-computed eligible indices, by
    ///     partition.
    ///   - file: The file to scope sources to, or `nil` for the whole
    ///     workspace.
    /// - Returns: The candidate source indices, in ascending index order
    ///   (matching `SearchCorpusSnapshot`'s chunk-id ordering).
    private static func sourceChunkIndices(snapshot: SearchCorpusSnapshot, eligibleByPartition: [Partition: [Int]], file: String?) -> [Int] {
        let eligible = eligibleByPartition.values.flatMap { $0 }.sorted()
        guard let file else {
            return eligible
        }
        return eligible.filter { snapshot.filePaths[$0] == file }
    }

    // MARK: - Grouping

    /// Builds one `DuplicateGroup` per source index with at least one
    /// duplicate, sorted by descending best-match similarity.
    ///
    /// Every source chunk in the same `Partition` is scored against that
    /// partition's candidate sub-matrix, gathered once via
    /// `partitionSubMatrix(cache:snapshot:partition:candidateIndices:)` and
    /// reused for the rest of that partition's sources — see this type's
    /// doc comment for why that (rather than re-gathering per source) is
    /// what makes workspace scope a true "matrix–matrix product per
    /// partition".
    private static func buildGroups(
        snapshot: SearchCorpusSnapshot,
        sourceIndices: [Int],
        eligibleByPartition: [Partition: [Int]],
        minSimilarity: Float,
        maxPerChunk: Int
    ) -> [DuplicateGroup] {
        var subMatrixCache: [Partition: [Float]] = [:]
        let groups = sourceIndices.compactMap { sourceIndex -> DuplicateGroup? in
            let partition = Partition.of(kind: snapshot.kinds[sourceIndex])
            let candidateIndices = eligibleByPartition[partition] ?? []
            let candidateSubMatrix = partitionSubMatrix(
                cache: &subMatrixCache, snapshot: snapshot, partition: partition, candidateIndices: candidateIndices
            )
            return duplicateGroup(
                snapshot: snapshot,
                sourceIndex: sourceIndex,
                candidateIndices: candidateIndices,
                candidateSubMatrix: candidateSubMatrix,
                minSimilarity: minSimilarity,
                maxPerChunk: maxPerChunk
            )
        }
        // Stable sort: ties keep `sourceIndices`' ascending chunk-id order,
        // mirroring the Rust reference's `sort_by` (also stable).
        return groups.sorted { lhs, rhs in
            (lhs.duplicates.first?.similarity ?? 0.0) > (rhs.duplicates.first?.similarity ?? 0.0)
        }
    }

    /// Returns `partition`'s gathered candidate sub-matrix from `cache`,
    /// building and caching it on first use.
    ///
    /// - Parameters:
    ///   - cache: The per-partition sub-matrix cache, shared across every
    ///     source chunk `buildGroups` processes.
    ///   - snapshot: The corpus snapshot to gather rows from.
    ///   - partition: The partition whose sub-matrix to return.
    ///   - candidateIndices: `partition`'s candidate duplicate indices.
    /// - Returns: The gathered `candidateIndices.count × embeddingDimension`
    ///   sub-matrix.
    private static func partitionSubMatrix(
        cache: inout [Partition: [Float]],
        snapshot: SearchCorpusSnapshot,
        partition: Partition,
        candidateIndices: [Int]
    ) -> [Float] {
        if let cached = cache[partition] {
            return cached
        }
        let built = snapshot.gatherSubMatrix(rowIndices: candidateIndices)
        cache[partition] = built
        return built
    }

    /// Scores `sourceIndex` against `candidateSubMatrix` (its own
    /// partition's already-gathered candidate rows), excluding self- and
    /// same-symbol pairs and anything below `minSimilarity`.
    ///
    /// - Parameters:
    ///   - snapshot: The corpus snapshot to read chunk data from.
    ///   - sourceIndex: The source chunk's index.
    ///   - candidateIndices: The candidate duplicate indices
    ///     `candidateSubMatrix` was gathered from — `sourceIndex`'s own
    ///     meta-type partition.
    ///   - candidateSubMatrix: `candidateIndices`' gathered embedding rows.
    ///   - minSimilarity: The minimum cosine similarity to report.
    ///   - maxPerChunk: The maximum number of duplicates to keep.
    /// - Returns: The source's duplicate group, or `nil` if no candidate
    ///   scored at or above `minSimilarity`.
    private static func duplicateGroup(
        snapshot: SearchCorpusSnapshot,
        sourceIndex: Int,
        candidateIndices: [Int],
        candidateSubMatrix: [Float],
        minSimilarity: Float,
        maxPerChunk: Int
    ) -> DuplicateGroup? {
        let queryVector = snapshot.embeddingRow(at: sourceIndex)
        let scores = CosineScoring.matvecScores(
            matrix: candidateSubMatrix,
            rowCount: candidateIndices.count,
            dimension: snapshot.embeddingDimension,
            queryVector: queryVector
        )

        let matches = zip(candidateIndices, scores)
            .filter { candidateIndex, score in
                score >= minSimilarity && !isExcludedPair(snapshot: snapshot, sourceIndex: sourceIndex, candidateIndex: candidateIndex)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(maxPerChunk)
            .map { candidateIndex, score in
                DuplicateMatch(chunk: chunkRef(snapshot: snapshot, chunkIndex: candidateIndex), similarity: Double(score))
            }

        guard !matches.isEmpty else {
            return nil
        }
        return DuplicateGroup(source: chunkRef(snapshot: snapshot, chunkIndex: sourceIndex), duplicates: Array(matches))
    }

    /// Determines whether `(sourceIndex, candidateIndex)` is a self-pair (the
    /// same chunk) or a same-symbol pair (a different chunk row sharing the
    /// exact same `(filePath, symbolPath)` identity) — either of which must
    /// never be reported as a duplicate match.
    private static func isExcludedPair(snapshot: SearchCorpusSnapshot, sourceIndex: Int, candidateIndex: Int) -> Bool {
        guard candidateIndex != sourceIndex else {
            return true
        }
        return snapshot.filePaths[candidateIndex] == snapshot.filePaths[sourceIndex]
            && snapshot.symbolPaths[candidateIndex] == snapshot.symbolPaths[sourceIndex]
    }

    /// Builds a `DuplicateChunkRef` from `snapshot`'s parallel arrays at `chunkIndex`.
    private static func chunkRef(snapshot: SearchCorpusSnapshot, chunkIndex: Int) -> DuplicateChunkRef {
        DuplicateChunkRef(
            filePath: snapshot.filePaths[chunkIndex],
            symbolPath: snapshot.symbolPaths[chunkIndex],
            kind: snapshot.kinds[chunkIndex],
            startLine: snapshot.startLines[chunkIndex],
            endLine: snapshot.endLines[chunkIndex],
            text: snapshot.texts[chunkIndex]
        )
    }
}

extension SearchCorpusSnapshot {
    /// Returns the L2-normalized embedding row at `rowIndex`, or an empty
    /// array if `rowIndex` is out of bounds or the corpus has no embedding
    /// dimension yet.
    ///
    /// - Parameter rowIndex: The chunk index (into this snapshot's parallel
    ///   arrays) whose embedding row to return.
    /// - Returns: The `embeddingDimension`-length row, or `[]` if `rowIndex`
    ///   doesn't address a valid row.
    func embeddingRow(at rowIndex: Int) -> [Float] {
        guard embeddingDimension > 0, rowIndex >= 0 else {
            return []
        }
        let start = rowIndex * embeddingDimension
        let end = start + embeddingDimension
        guard end <= embeddingMatrix.count else {
            return []
        }
        return Array(embeddingMatrix[start..<end])
    }

    /// Gathers the embedding rows at `rowIndices` into one contiguous,
    /// row-major `rowIndices.count × embeddingDimension` sub-matrix — the
    /// `FindDuplicatesOps` partition-scoped input to
    /// `RankKit.CosineScoring.matvecScores(matrix:rowCount:dimension:queryVector:)`, built
    /// once per partition and then reused across every source chunk in that
    /// partition rather than re-gathered per source.
    ///
    /// - Parameter rowIndices: The chunk indices (into this snapshot's
    ///   parallel arrays) whose rows to gather, in the order they should
    ///   appear in the sub-matrix.
    /// - Returns: The gathered sub-matrix; empty if `rowIndices` is empty.
    func gatherSubMatrix(rowIndices: [Int]) -> [Float] {
        guard !rowIndices.isEmpty else {
            return []
        }
        var subMatrix: [Float] = []
        subMatrix.reserveCapacity(rowIndices.count * embeddingDimension)
        for rowIndex in rowIndices {
            subMatrix.append(contentsOf: embeddingRow(at: rowIndex))
        }
        return subMatrix
    }
}
