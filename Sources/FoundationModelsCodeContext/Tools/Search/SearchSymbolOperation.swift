import FoundationModels
import Operations

/// The `search symbol` operation of the `code_search` tool.
///
/// It finds the symbols whose name is near `query`, with a fuzzy match, and
/// can keep only the symbols of one kind.
@Generable
@Operation(
    verb: "search",
    noun: "symbol",
    description: "Find the symbols whose name is near the query, with a fuzzy match. You can keep only one kind of symbol."
)
internal struct SearchSymbolOperation {
    /// The text to search for.
    @Guide(
        description:
            "Text to search for: a symbol name for `get symbol` and `search symbol`, or free text for `search code`."
    )
    @OperationParam(aliases: ["name", "symbol"])
    var query: String

    /// The kind of symbol to keep, or `nil` for all kinds.
    @Guide(
        description: "The kind of symbol to keep: function, method, type or other. If you do not give a kind, all kinds are kept.",
        .anyOf(["function", "method", "type", "other"])
    )
    @OperationParam(aliases: ["symbolKind", "type"])
    var kind: String?

    /// The maximum number of results, or `nil` for the default.
    @Guide(description: "The maximum number of results to give.")
    @OperationParam(aliases: ["limit", "max"])
    var maxResults: Int?
}

extension SearchSymbolOperation {
    /// The allowed names of `kind`, and the symbol kind of each name.
    static let kindChoices = ToolSupport.choiceTable(for: SymbolMetaType.self)

    /// Calls `searchSymbol(query:kind:maxResults:)`.
    ///
    /// - Parameter context: The tool context.
    /// - Returns: The engine result, or a corrective message.
    /// - Throws: An error that the model cannot correct.
    func execute(in context: CodeContextToolContext) async throws -> ToolOutcome<[SearchSymbolMatch]> {
        let parse = ToolSupport.parseOptionalChoice(kind, choices: Self.kindChoices, parameter: "kind")
        return try await ToolSupport.outcome(after: parse) { symbolKind in
            try await context.operating.searchSymbol(
                query: query,
                kind: symbolKind,
                maxResults: maxResults ?? CodeContextDefaults.maxQueryResults
            )
        }
    }
}
