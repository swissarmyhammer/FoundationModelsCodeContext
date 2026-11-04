import FoundationModelsRanker
import Tracing

/// Makes the selection configuration for one search, given the ids of the candidates of that
/// search.
///
/// The host picks the selection model. This package ships no model, and a `CodeContext` cannot be
/// made without a factory: there is no default and no retrieval-only mode. This is the same shape
/// as `SelectionFactory` of FoundationModelsMultitool.
///
/// The package applies the factory one time for each search, after retrieval, with every id of
/// the candidates in retrieval order. A host can use the ids to fit the configuration to the
/// search, for example to pick a capacity budget. `SelectionConfig.model` is the model that
/// answers the selection prompt. The selection tier makes a new `LanguageModelSession` on it for
/// each prompt.
///
/// A search with no candidate does not apply the factory.
///
/// When the factory throws, or the selection session fails, the error is the error of the
/// search. The package does not catch it, and it does not answer with the retrieval result.
///
/// - Parameter ids: The ids of the candidates, in retrieval order.
/// - Returns: The selection configuration for this search.
/// - Throws: What the host throws while it makes the configuration.
public typealias SelectionFactory = @Sendable (_ ids: [String]) throws -> SelectionConfig

/// One candidate of a search: the retrieval match, and the text that the selection model reads.
///
/// `Payload` is what the search gives back for the candidate: a `SearchCodeMatch` for one root, a
/// root-qualified match for a manager.
internal struct SelectionCandidate<Payload: Sendable>: Sendable {
    /// The id that the selection model answers with. It is unique in one search.
    let id: String

    /// The short text that the selection prompt shows for the candidate.
    let summary: String

    /// The verbatim chunk text that the selection tier gives back for the id.
    let block: String

    /// What the search gives back when the model selects this candidate.
    let payload: Payload
}

/// The `SelectionCatalog` of one search, over its candidates.
///
/// The catalog is made for each search and it is never reused. The order of `ids` is the order of
/// the prompt, which is the retrieval order.
internal struct CandidateCatalog: SelectionCatalog {
    /// The ids of the candidates, in retrieval order.
    let ids: [String]

    /// The summary of each candidate, by id.
    private let summaries: [String: String]

    /// The verbatim block of each candidate, by id.
    private let blocks: [String: String]

    /// Makes the catalog of `candidates`.
    ///
    /// - Parameter candidates: The candidates, in retrieval order, with unique ids.
    init<Payload>(_ candidates: [SelectionCandidate<Payload>]) {
        ids = candidates.map(\.id)
        summaries = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0.summary) })
        blocks = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0.block) })
    }

    /// The summary of `id`, or `nil` when `id` is not a candidate.
    func summaryBlock(forID id: String) -> String? {
        summaries[id]
    }

    /// The verbatim chunk text of `id`, or `nil` when `id` is not a candidate.
    func block(forID id: String) -> String? {
        blocks[id]
    }
}

/// The selection step of a search: a selection model picks and orders the retrieval candidates.
internal enum CodeSelection {
    /// Lets the selection model of `factory` pick and order `candidates` for `query`.
    ///
    /// The factory runs one time, with the ids of all candidates. The tier is new for each call,
    /// because it keeps no state. A search with no candidate returns at once: it applies no
    /// factory and it calls no model. An error of the factory or of the model session is not
    /// caught. It is the error of the search.
    ///
    /// The step runs in one `CodeContextTracing.SpanName.select` span, a child of the search span
    /// that is open in the caller. The span holds the candidate count and the result count. It
    /// never holds the query or the text of a candidate.
    ///
    /// - Parameters:
    ///   - candidates: The retrieval candidates, in retrieval order, with unique ids.
    ///   - query: The query that the model reads as the request.
    ///   - limit: The maximum number of payloads to return.
    ///   - factory: Makes the selection configuration from the candidate ids.
    ///   - tracer: The tracer of the select span, or `nil` to read the bootstrapped tracer now.
    /// - Returns: The payload of each selected candidate, in the order of the model.
    /// - Throws: What `factory` throws, and what the selection session throws.
    static func select<Payload: Sendable>(
        _ candidates: [SelectionCandidate<Payload>],
        query: String,
        limit: Int,
        factory: SelectionFactory,
        tracer: (any Tracer)?
    ) async throws -> [Payload] {
        guard !candidates.isEmpty else { return [] }
        return try await CodeContextSpans.withSelectionSpan(
            tracer: tracer,
            candidateCount: candidates.count,
            resultCount: \.count
        ) {
            let catalog = CandidateCatalog(candidates)
            let tier = SelectionTier(
                catalog: catalog,
                config: try factory(catalog.ids),
                onDiagnostic: SelectionDiagnostics.write
            )
            let selected = try await tier.search(intent: query, limit: limit)

            let payloadByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0.payload) })
            return selected.compactMap { payloadByID[$0.id] }
        }
    }
}

/// Writes the diagnostics of the selection tier to the search log of this package.
internal enum SelectionDiagnostics {
    /// The message of the record for an id that is not a candidate.
    static let unknownSelectedIDMessage = "the selection model answered an id that is not a candidate; the id is dropped"

    /// The message of the record for a candidate cut that the tier reports.
    static let retrievalCutMessage = "the selection tier cut the candidates"

    /// The message of the record for a retrieval that had no similarity signal.
    static let embeddingUnavailableMessage = "the selection tier reported no similarity signal"

    /// Writes one record for `diagnostic`.
    ///
    /// The record has a fixed message and no metadata. The id of an unknown candidate is output of
    /// the model, so it is not a safe value. The record never holds the query or the text of a
    /// chunk.
    ///
    /// - Parameter diagnostic: The diagnostic of the selection tier.
    static func write(_ diagnostic: RankDiagnostic) {
        switch diagnostic {
        case .unknownSelectedId:
            Log.search.warning(.init(stringLiteral: unknownSelectedIDMessage))
        case .retrievalCut:
            Log.search.warning(.init(stringLiteral: retrievalCutMessage))
        case .embeddingUnavailable:
            Log.search.warning(.init(stringLiteral: embeddingUnavailableMessage))
        }
    }
}

extension SearchCodeMatch {
    /// The candidate of this match in a selection prompt.
    ///
    /// The summary is the symbol path with the kind and the file. The block is the verbatim chunk
    /// text.
    ///
    /// - Parameters:
    ///   - id: The id of the candidate.
    ///   - summaryPrefix: Text before the summary, for example the name of the root. Empty for one
    ///     root.
    ///   - payload: What the search gives back when the model selects the candidate.
    /// - Returns: The candidate.
    func selectionCandidate<Payload: Sendable>(
        id: String, summaryPrefix: String = "", payload: Payload
    ) -> SelectionCandidate<Payload> {
        SelectionCandidate(
            id: id,
            summary: "\(summaryPrefix)\(symbolPath) (\(kind.rawValue)) in \(filePath)",
            block: text,
            payload: payload
        )
    }
}
