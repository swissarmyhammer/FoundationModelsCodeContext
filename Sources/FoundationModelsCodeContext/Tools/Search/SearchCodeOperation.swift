import FoundationModels
import Operations

/// The `search code` operation of the `code_search` tool.
///
/// It finds the code chunks that are near a free-text query. The rank uses the
/// words of the text and the meaning of the text.
@Generable
@Operation(
    verb: "search",
    noun: "code",
    description: "Find the code chunks that are near a free-text query. The rank uses the words of the text and the meaning of the text."
)
internal struct SearchCodeOperation {
    /// The text to search for.
    @Guide(
        description:
            "Text to search for: a symbol name for `get symbol` and `search symbol`, or free text for `search code`."
    )
    @OperationParam(aliases: ["text", "q"])
    var query: String

    /// The number of hits, or `nil` for the default.
    @Guide(description: "The number of hits to give.")
    @OperationParam(aliases: ["limit", "maxResults", "k"])
    var topK: Int?
}

extension SearchCodeOperation {
    /// Calls `searchCode(query:topK:weights:)`.
    ///
    /// - Parameter context: The tool context.
    /// - Returns: The engine result, or a corrective message.
    /// - Throws: An error that the model cannot correct.
    func execute(in context: CodeContextToolContext) async throws -> ToolOutcome<SearchCodeResult> {
        try await ToolSupport.outcome {
            try await context.operating.searchCode(
                query: query,
                topK: topK ?? CodeContextDefaults.searchTopK,
                weights: CodeContextDefaults.searchWeights
            )
        }
    }
}
