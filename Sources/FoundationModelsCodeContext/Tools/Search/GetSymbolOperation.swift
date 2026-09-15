import FoundationModels
import Operations

/// The `get symbol` operation of the `code_search` tool.
///
/// It finds the symbols whose name matches `query`, and gives the location and
/// the source text of each symbol.
@Generable
@Operation(
    verb: "get",
    noun: "symbol",
    description: "Find the symbols whose name matches the query, and give the location and the source text of each symbol."
)
internal struct GetSymbolOperation {
    /// The text to search for.
    @Guide(
        description:
            "Text to search for: a symbol name for `get symbol` and `search symbol`, or free text for `search code`."
    )
    @OperationParam(aliases: ["name", "symbol"])
    var query: String

    /// The maximum number of results, or `nil` for the default.
    @Guide(description: "The maximum number of results to give.")
    @OperationParam(aliases: ["limit", "max"])
    var maxResults: Int?
}

extension GetSymbolOperation {
    /// Calls `getSymbol(query:maxResults:)`.
    ///
    /// - Parameter context: The tool context.
    /// - Returns: The engine result, or a corrective message.
    /// - Throws: An error that the model cannot correct.
    func execute(in context: CodeContextToolContext) async throws -> ToolOutcome<GetSymbolResult> {
        try await ToolSupport.outcome {
            try await context.operating.getSymbol(
                query: query,
                maxResults: maxResults ?? CodeContextDefaults.maxQueryResults
            )
        }
    }
}
