import FoundationModels
import Operations

/// The `query ast` operation of the `code_search` tool.
///
/// It runs a tree-sitter S-expression query on the files of one language, and
/// gives each match.
@Generable
@Operation(
    verb: "query",
    noun: "ast",
    description: "Run a tree-sitter S-expression query on the files of one language, and give each match with its captures."
)
internal struct QueryAstOperation {
    /// The language of the files to query.
    @Guide(description: "The name of the language of the files to query, for example swift or rust.")
    @OperationParam(aliases: ["lang"])
    var language: String

    /// The S-expression query.
    ///
    /// The name of this parameter is not `query`, because `query` is the name
    /// of the symbol query and of the text query of this tool.
    @Guide(description: "A tree-sitter S-expression query, for example `(function_declaration) @function`.")
    @OperationParam(aliases: ["query", "sexp", "pattern"])
    var astQuery: String

    /// The maximum number of matches, or `nil` for the default.
    @Guide(description: "The maximum number of results to give.")
    @OperationParam(aliases: ["limit", "max"])
    var maxResults: Int?
}

extension QueryAstOperation {
    /// Calls `queryAST(language:query:options:)`.
    ///
    /// - Parameter context: The tool context.
    /// - Returns: The engine result, or a corrective message.
    /// - Throws: An error that the model cannot correct.
    func execute(in context: CodeContextToolContext) async throws -> ToolOutcome<QueryASTResult> {
        try await ToolSupport.outcome {
            try await context.operating.queryAST(
                language: language,
                query: astQuery,
                options: QueryASTOptions(maxResults: maxResults ?? CodeContextDefaults.queryASTMaxResults)
            )
        }
    }
}
